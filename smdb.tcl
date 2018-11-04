#! /usr/bin/env wish

package require sqlite3

sqlite3 db "music.sqlite"

db eval {CREATE TABLE IF NOT EXISTS tunes (id INTEGER PRIMARY KEY ASC AUTOINCREMENT,
                                           name TEXT ASC)}
db eval {CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY ASC AUTOINCREMENT,
                                           title TEXT ASC,
                                           author TEXT ASC,
                                           instrument TEXT ASC,
                                           duet BOOLEAN)}
db eval {CREATE TABLE IF NOT EXISTS book2tune (id INTEGER PRIMARY KEY ASC AUTOINCREMENT,
                                                 bookid INTEGER REFERENCES books(id),
                                                 tuneid INTEGER REFERENCES tunes(id))}
db eval {PRAGMA foreign_keys=ON}

# Taken from SQLite documentation and lightly modified.
namespace eval ::undo {

# proc:  ::undo::activate TABLE ...
# title: Start up the undo/redo system
#
# Arguments should be one or more database tables (in the database associated
# with the handle "db") whose changes are to be recorded for undo/redo
# purposes.
#
proc activate {args} {
	variable _undo
	if {$_undo(active)} return
	eval _create_triggers db $args
	set _undo(undostack) {}
	set _undo(redostack) {}
	set _undo(active) 1
	set _undo(freeze) -1
	_start_interval
	status_refresh
}

# proc:  ::undo::deactivate
# title: Halt the undo/redo system and delete the undo/redo stacks
#
proc deactivate {} {
	variable _undo
	if {!$_undo(active)} return
	_drop_triggers db
	set _undo(undostack) {}
	set _undo(redostack) {}
	set _undo(active) 0
	set _undo(freeze) -1
}

# proc:  ::undo::freeze
# title: Stop accepting database changes into the undo stack
#
# From the point when this routine is called up until the next unfreeze,
# new database changes are rejected from the undo stack.
#
proc freeze {} {
	variable _undo
	if {![info exists _undo(freeze)]} return
	if {$_undo(freeze)>=0} {error "recursive call to ::undo::freeze"}
	set _undo(freeze) [db one {SELECT coalesce(max(seq),0) FROM undolog}]
}

# proc:  ::undo::unfreeze
# title: Begin accepting undo actions again.
#
proc unfreeze {} {
	variable _undo
	if {![info exists _undo(freeze)]} return
	if {$_undo(freeze)<0} {error "called ::undo::unfreeze while not frozen"}
	db eval "DELETE FROM undolog WHERE seq>$_undo(freeze)"
	set _undo(freeze) -1
}

# proc:  ::undo::event
# title: Something undoable has happened
#
# This routine is called whenever an undoable action occurs.  Arrangements
# are made to invoke ::undo::barrier no later than the next idle moment.
#
proc event {} {
		variable _undo
		if {$_undo(pending)==""} {
			set _undo(pending) [after idle ::undo::barrier]
	}
}

# proc:  ::undo::barrier
# title: Create an undo barrier right now.
#
proc barrier {} {
	variable _undo
	catch {after cancel $_undo(pending)}
	set _undo(pending) {}
	if {!$_undo(active)} {
		refresh
		return
	}
	set end [db one {SELECT coalesce(max(seq),0) FROM undolog}]
	if {$_undo(freeze)>=0 && $end>$_undo(freeze)} {set end $_undo(freeze)}
	set begin $_undo(firstlog)
	_start_interval
	if {$begin==$_undo(firstlog)} {
		refresh
		return
	}
	lappend _undo(undostack) [list $begin $end]
	set _undo(redostack) {}
	refresh
}

# proc:  ::undo::undo
# title: Do a single step of undo
#
proc undo {} {
	_step undostack redostack
}

# proc:  ::undo::redo
# title: Redo a single step
#
proc redo {} {
	_step redostack undostack
}

# proc:   ::undo::refresh
# title:  Update the status of controls after a database change
#
# The undo module calls this routine after any undo/redo in order to
# cause controls gray out appropriately depending on the current state
# of the database.  This routine works by invoking the status_refresh
# module in all top-level namespaces.
#
proc refresh {} {
	set body {}
	foreach ns [namespace children ::] {
		if {[info proc ${ns}::status_refresh]==""} continue
		append body ${ns}::status_refresh\n
	}
	proc ::undo::refresh {} $body
	refresh
}

# proc:   ::undo::reload_all
# title:  Redraw everything based on the current database
#
# The undo module calls this routine after any undo/redo in order to
# re-run the search if that window is open,
proc reload_all {} {
	if {[winfo exists .search]} {
		gui_search
	}
}

##############################################################################
# The public interface to this module is above.  Routines and variables that
# follow (and whose names begin with "_") are private to this module.
##############################################################################

# state information
#
set _undo(active) 0
set _undo(undostack) {}
set _undo(redostack) {}
set _undo(pending) {}
set _undo(firstlog) 1
set _undo(startstate) {}


# proc:  ::undo::status_refresh
# title: Enable and/or disable menu options a buttons
#
proc status_refresh {} {
	variable _undo
	if {!$_undo(active) || [llength $_undo(undostack)]==0} {
		.entry.f.undo state disabled
	} else {
		.entry.f.undo state !disabled
	}
	if {!$_undo(active) || [llength $_undo(redostack)]==0} {
		.entry.f.redo state disabled
	} else {
		.entry.f.redo state !disabled
	}
}

# xproc:  ::undo::_create_triggers DB TABLE1 TABLE2 ...
# title:  Create change recording triggers for all tables listed
#
# Create a temporary table in the database named "undolog".  Create
# triggers that fire on any insert, delete, or update of TABLE1, TABLE2, ....
# When those triggers fire, insert records in undolog that contain
# SQL text for statements that will undo the insert, delete, or update.
#
proc _create_triggers {db args} {
	catch {$db eval {DROP TABLE undolog}}
	$db eval {CREATE TEMP TABLE undolog(seq integer primary key, sql text)}
	foreach tbl $args {
		set collist [$db eval "pragma table_info($tbl)"]
		set sql "CREATE TEMP TRIGGER _${tbl}_it AFTER INSERT ON $tbl BEGIN\n"
		append sql "  INSERT INTO undolog VALUES(NULL,"
		append sql "'DELETE FROM $tbl WHERE rowid='||new.rowid);\nEND;\n"

		append sql "CREATE TEMP TRIGGER _${tbl}_ut AFTER UPDATE ON $tbl BEGIN\n"
		append sql "  INSERT INTO undolog VALUES(NULL,"
		append sql "'UPDATE $tbl "
		set sep "SET "
		foreach {x1 name x2 x3 x4 x5} $collist {
			append sql "$sep$name='||quote(old.$name)||'"
			set sep ","
		}
		append sql " WHERE rowid='||old.rowid);\nEND;\n"

		append sql "CREATE TEMP TRIGGER _${tbl}_dt BEFORE DELETE ON $tbl BEGIN\n"
		append sql "  INSERT INTO undolog VALUES(NULL,"
		append sql "'INSERT INTO ${tbl}(rowid"
		foreach {x1 name x2 x3 x4 x5} $collist {append sql ,$name}
		append sql ") VALUES('||old.rowid||'"
		foreach {x1 name x2 x3 x4 x5} $collist {append sql ,'||quote(old.$name)||'}
		append sql ")');\nEND;\n"

		$db eval $sql
	}
}

# xproc:  ::undo::_drop_triggers DB
# title:  Drop all of the triggers that _create_triggers created
#
proc _drop_triggers {db} {
	set tlist [$db eval {SELECT name FROM sqlite_temp_master WHERE type='trigger'}]
	foreach trigger $tlist {
		if {![regexp {^_.*_(i|u|d)t$} $trigger]} continue
		$db eval "DROP TRIGGER $trigger;"
	}
	catch {$db eval {DROP TABLE undolog}}
}

# xproc: ::undo::_start_interval
# title: Record the starting conditions of an undo interval
#
proc _start_interval {} {
	variable _undo
	set _undo(firstlog) [db one {SELECT coalesce(max(seq),0)+1 FROM undolog}]
}

# xproc: ::undo::_step V1 V2
# title: Do a single step of undo or redo
#
# For an undo V1=="undostack" and V2=="redostack".  For a redo,
# V1=="redostack" and V2=="undostack".
#
proc _step {v1 v2} {
	variable _undo
	set op [lindex $_undo($v1) end]
	set _undo($v1) [lrange $_undo($v1) 0 end-1]
	foreach {begin end} $op break
	db eval BEGIN
	set q1 "SELECT sql FROM undolog WHERE seq>=$begin AND seq<=$end
		ORDER BY seq DESC"
	set sqllist [db eval $q1]
	db eval "DELETE FROM undolog WHERE seq>=$begin AND seq<=$end"
	set _undo(firstlog) [db one {SELECT coalesce(max(seq),0)+1 FROM undolog}]
	foreach sql $sqllist {
		db eval $sql
	}
	db eval COMMIT
	reload_all

	set end [db one {SELECT coalesce(max(seq),0) FROM undolog}]
	set begin $_undo(firstlog)
	lappend _undo($v2) [list $begin $end]
	_start_interval
	refresh
}


# End of the ::undo namespace
}

set themes [ttk::style theme names]
if {[lsearch $themes aqua] >= 0} {
	ttk::style theme use aqua
} elseif {[lsearch $themes vista] >= 0} {
	ttk::style theme use vista
} elseif {[lsearch $themes xpnative] >= 0} {
	ttk::style theme use xpnative
} elseif {[lsearch $themes winnative] >= 0} {
	ttk::style theme use winnative
} elseif {[lsearch $themes clam] >= 0} {
	# clam shows keyboard focus for comboboxes, unlike alt/default/classic
	ttk::style theme use clam
}

proc pad_grid_widgets {widget_list {amt 4}} {
	foreach widget $widget_list {
		grid configure $widget -padx $amt -pady $amt
	}
}

proc create_entry {} {
	toplevel .entry
	wm title .entry "Sheet Music Database: Data Entry"
	ttk::frame .entry.f

	ttk::frame .entry.f.erow

	ttk::label .entry.f.erow.titlel -text "Book Title"
	ttk::label .entry.f.erow.authorl -text "Book Author"
	ttk::label .entry.f.erow.instrumentl -text "Book Instrument"
	ttk::label .entry.f.erow.duetl -text "Duets?"
	ttk::label .entry.f.erow.namel -text "Hymn Tune"
	ttk::entry .entry.f.erow.title
	ttk::entry .entry.f.erow.author
	ttk::combobox .entry.f.erow.instrument -state readonly -values {organ piano}
	              .entry.f.erow.instrument set organ
	ttk::checkbutton .entry.f.erow.duet
	ttk::entry .entry.f.erow.name
	ttk::button .entry.f.erow.enter -text Enter -command gui_enter -takefocus 0

	ttk::separator .entry.f.sep1 -orient vertical -takefocus 0

	ttk::button .entry.f.undo -text "Undo" -command ::undo::undo -takefocus 0
	ttk::button .entry.f.redo -text "Redo" -command ::undo::redo -takefocus 0

	grid .entry.f -sticky nsew

	grid .entry.f.undo -sticky nsew
	grid .entry.f.redo -sticky nsew
	grid .entry.f.sep1 -row 0 -column 1 -rowspan 2 -sticky nsew
	grid .entry.f.erow -row 0 -column 2 -rowspan 2 -sticky w

	grid .entry.f.erow.titlel .entry.f.erow.title -sticky ew
	grid .entry.f.erow.authorl .entry.f.erow.author -sticky ew
	grid .entry.f.erow.instrumentl .entry.f.erow.instrument -sticky ew
	grid .entry.f.erow.duetl .entry.f.erow.duet -sticky ew
	grid .entry.f.erow.namel .entry.f.erow.name -sticky ew
	grid .entry.f.erow.enter -column 1 -sticky nsew

	pad_grid_widgets [winfo children .entry.f.erow] 2
	pad_grid_widgets [winfo children .entry.f] 4

	grid columnconfigure .entry 0 -weight 1
	grid rowconfigure .entry 0 -weight 1

	grid columnconfigure .entry.f 0 -weight 1
	grid columnconfigure .entry.f 1 -weight 1
	grid rowconfigure .entry.f 0 -weight 1
	grid rowconfigure .entry.f 1 -weight 1

	grid columnconfigure .entry.f.erow 1 -weight 1

	bind .entry <Control-Z> ::undo::undo
	bind .entry <Control-Y> ::undo::redo
	bind .entry <Control-R> ::undo::redo

	bind .entry <Return> {gui_enter}

	::undo::activate books tunes book2tune
}

set searchtype book
proc create_search {} {
	toplevel .search
	wm title .search "Sheet Music Database: Music Search"
	ttk::frame .search.f

	ttk::labelframe .search.f.tf -text "By tune:"
	ttk::label .search.f.tf.tunel -text "Name:  "
	ttk::radiobutton .search.f.tf.entune -value tune -variable searchtype -command search_entune
	ttk::entry .search.f.tf.tune

	ttk::labelframe .search.f.bf -text "By book:"
	ttk::radiobutton .search.f.bf.enbook -value book -variable searchtype -command search_enbook

	ttk::label .search.f.bf.titlel -text "Title: "
	ttk::entry .search.f.bf.title

	ttk::label .search.f.bf.authorl -text "Author: "
	ttk::entry .search.f.bf.author

	ttk::button .search.f.go -text "Search" -command gui_search

	ttk::treeview .search.f.results -height 24 -show tree
	              .search.f.results column #0 -width 320

	grid .search.f -sticky nsew

	grid .search.f.tf.entune .search.f.tf.tunel -sticky w
	grid .search.f.tf.tune -row 0 -column 2 -sticky e

	grid .search.f.bf.enbook .search.f.bf.titlel -sticky w
	grid .search.f.bf.title -row 0 -column 2 -sticky e
	grid x .search.f.bf.authorl -sticky w
	grid .search.f.bf.author -row 1 -column 2 -sticky e
	

	grid .search.f.tf -sticky nsew
	grid .search.f.bf -sticky nsew
	grid .search.f.go -sticky e
	grid .search.f.results -sticky nsew

	pad_grid_widgets [winfo children .search.f.tf] 4
	pad_grid_widgets [winfo children .search.f.bf] 4
	pad_grid_widgets [winfo children .search.f] 4

	grid columnconfigure .search 0 -weight 1
	grid rowconfigure .search 0 -weight 1

	grid columnconfigure .search.f.tf 2 -weight 1
	grid columnconfigure .search.f.bf 2 -weight 1

	grid columnconfigure .search.f 0 -weight 1
	grid rowconfigure .search.f 3 -weight 1

	bind .search <Return> gui_search

	bind .search.f.tf.tune <ButtonPress> {.search.f.tf.entune invoke}
	bind .search.f.bf.title <ButtonPress> {.search.f.bf.entune invoke}
	bind .search.f.bf.author <ButtonPress> {.search.f.bf.entune invoke}

	search_enbook
}

proc search_entune {} {
	.search.f.tf.tune state !disabled
	.search.f.bf.title state disabled
	.search.f.bf.author state disabled
}

proc search_enbook {} {
	.search.f.tf.tune state disabled
	.search.f.bf.title state !disabled
	.search.f.bf.author state !disabled
}

proc gui_enter {} {
	addrow
	.entry.f.erow.name delete 0 end
	::undo::event

	if {[winfo exists .search]} {
		gui_search
	}
}

proc gui_search {} {
	global searchtype
	switch $searchtype {
		tune {
			.search.f.results delete [.search.f.results children {}]
			dict for {author titles} [books_by_tune [.search.f.tf.tune get]] {
				set rauthor [.search.f.results insert {} end -text $author -open true]
				foreach title $titles {
					.search.f.results see [.search.f.results insert $rauthor end -text $title]
				}
			}
		}
		book {
			.search.f.results delete [.search.f.results children {}]
			dict for {author titles} [books_by_book [.search.f.bf.title get] [.search.f.bf.author get]] {
				set rauthor [.search.f.results insert {} end -text $author -open true]
				foreach title $titles {
					dict for {title tunes} $title {
						set rbook [.search.f.results insert $rauthor end -text $title -open true]
						foreach tune $tunes {
							.search.f.results see [.search.f.results insert $rbook end -text "$tune"]
						}
					}
				}
			}
		}
		default {
			puts "warning: invalid searchtype $searchtype"
		}
	}
}

proc addrow {} {
	global histsql
	# Get our values as Tcl variables for sqlite's eval command
	set title [.entry.f.erow.title get]
	set author [.entry.f.erow.author get]
	set instrument [.entry.f.erow.instrument get]
	set duet [expr {[lsearch [.entry.f.erow.duet state] "selected"] >= 0}]
	set name [.entry.f.erow.name get]
	
	set book ""
	set tune ""

	if {[string length $title] > 0 && [string length $author] > 0} {
		set book [db eval {SELECT id FROM books WHERE title = $title AND author = $author}]
		# If the book exists, book should now have a single element.
		switch [llength $book] {
			0 {
				# Create a new book
				db eval {INSERT INTO books VALUES(NULL, $title, $author, $instrument, $duet)}
				set book [db last_insert_rowid]
			}
			1 {
				# We use the existing book, no change
			}
			default
			{
				puts "warning: inconsistent database! books $book are identical"
				puts "using [lindex $book 0]"
				set book [lindex $book 0]
			}
		}
	} else {
		puts "warning: book title and/or author empty, ignoring"
	}

	set tune [db eval {SELECT id FROM tunes WHERE name = $name}]

	if {[string length $name] > 0} {
		# See books above.
		switch [llength $tune] {
			0 {
				# Create a new tune
				db eval {INSERT INTO tunes VALUES(NULL, $name)}
				set tune [db last_insert_rowid]
			}
			1 {
				# We use the existing tune, no change
			}
			default
			{
				puts "warning: inconsistent database! tunes $tune are identical"
				puts "using [lindex $tune 0]"
				set book [lindex $tune 0]
			}
		}
	} else {
		puts "warning: tune name empty, ignoring"
	}

	if {[llength $book] > 0 && [llength $tune] > 0} {
		if {![db exists {SELECT id FROM book2tune WHERE bookid=$book AND tuneid=$tune}]} {
			db eval {INSERT INTO book2tune VALUES(NULL, $book, $tune)}
		} else {
			puts "warning: tried to re-add existing relationship between book $book and tune $tune"
		}
	}
}

# Returns a dict where keys are authors and values are book titles
proc books_by_tune {tune} {
	set ret [dict create]
	set tuneid [db onecolumn {SELECT id FROM tunes WHERE name = $tune}]
	db eval {SELECT bookid FROM book2tune WHERE tuneid = $tuneid} {
		dict lappend ret [db onecolumn {SELECT author FROM books WHERE id = $bookid}]\
		                 [db eval {SELECT title FROM books WHERE id = $bookid}]
	}
	return $ret
}

# Returns a dict where keys are authors and values are dicts where the keys are
# titles and the values are tunes
proc books_by_book {title author} {
	set ret [dict create]
	set books ""

	if {[string length $title] > 0 && [string length $author] > 0} {
		# Should really be unique, but we won't enforce this
		set books [db eval {SELECT id FROM books WHERE title = $title AND author = $author}]
	} elseif {[string length $title] > 0} {
		set books [db eval {SELECT id FROM books WHERE title = $title}]
	} elseif {[string length $author] > 0} {
		set books [db eval {SELECT id FROM books WHERE author = $author}]
	} else {
		set books [db eval {SELECT id FROM books}]
	}

	foreach book $books {
		set title [db onecolumn {SELECT title FROM books WHERE id = $book}]
		set instrument [db onecolumn {SELECT instrument FROM books WHERE id = $book}]
		set duet ""
		if {[db onecolumn {SELECT duet FROM books WHERE id = $book}]} {
			set duet " (duet)"
		}
		set tunes {}
		db eval {SELECT tuneid FROM book2tune WHERE bookid = $book} {
			lappend tunes [db onecolumn {SELECT name FROM tunes WHERE id = $tuneid}]
		}


		dict lappend ret [db onecolumn {SELECT author FROM books WHERE id = $book}]\
		                 [dict create [string cat $title " ($instrument)" $duet] $tunes]
	}

	return $ret
}

wm title . "Sheet Music Database"

ttk::frame .f
ttk::button .f.entry -text "Data Entry" -command {if {![winfo exists .entry]} {create_entry}}

ttk::button .f.search -text "Music Search" -command {if {![winfo exists .search]} {create_search}}

grid .f -sticky nsew
grid .f.entry .f.search

grid columnconfigure . 0 -weight 1
grid rowconfigure . 0 -weight 1

grid columnconfigure .f 0 -weight 1
grid columnconfigure .f 1 -weight 1
grid rowconfigure .f 0 -weight 1

pad_grid_widgets [winfo children .f] 4
