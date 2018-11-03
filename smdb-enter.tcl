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
		puts "foo!"
		if {$_undo(pending)==""} {
			set _undo(pending) [after idle ::undo::barrier]
	}
}

# proc:  ::undo::barrier
# title: Create an undo barrier right now.
#
proc barrier {} {
	variable _undo
	puts "bar!"
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
# cause the screen to be completely redrawn based on the current database
# contents.  This is accomplished by calling the "reload" module in
# every top-level namespace other than ::undo.
#
proc reload_all {} {
	set body {}
	foreach ns [namespace children ::] {
		if {[info proc ${ns}::reload]==""} continue
		append body ${ns}::reload\n
	}
	proc ::undo::reload_all {} $body
	reload_all
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
	if {[winfo exists .hist]} {
		if {!$_undo(active) || [llength $_undo(undostack)]==0} {
			.hist.f.undo state disabled
		} else {
			.hist.f.undo state !disabled
		}
		if {!$_undo(active) || [llength $_undo(redostack)]==0} {
			.hist.f.redo state disabled
		} else {
			.hist.f.redo state !disabled
		}
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
::undo::activate

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

ttk::frame .t

ttk::frame .t.erow
wm title . "Sheet Music Database: Entry"

ttk::label .t.erow.titlel -text "Book Title"
ttk::label .t.erow.authorl -text "Book Author"
ttk::label .t.erow.instrumentl -text "Book Instrument"
ttk::label .t.erow.duetl -text "Duets?"
ttk::label .t.erow.namel -text "Hymn Tune"
ttk::entry .t.erow.title
ttk::entry .t.erow.author
ttk::combobox .t.erow.instrument -state readonly -values {organ piano}
ttk::checkbutton .t.erow.duet
ttk::entry .t.erow.name
ttk::button .t.erow.enter -text Enter -command gui_enter -takefocus 0

ttk::separator .t.sep -orient vertical -takefocus 0

ttk::button .t.histb -text "Undo History" -command create_hist -takefocus 0

grid .t.erow.titlel .t.erow.authorl .t.erow.instrumentl .t.erow.duetl .t.erow.namel -sticky nsew
grid .t.erow.title .t.erow.author .t.erow.instrument .t.erow.duet .t.erow.name .t.erow.enter -sticky nsew

grid .t.histb .t.sep .t.erow -sticky nsew

grid rowconfigure .t 0 -weight 1

pack .t

foreach widget [winfo children .t.erow] {
	grid configure $widget -padx 2 -pady 2
}
foreach widget [winfo children .t] {
	grid configure $widget -padx 4 -pady 4
}

.t.erow.instrument set organ

bind . <Control-Z> ::undo::undo
bind . <Control-Y> ::undo::redo
bind . <Control-R> ::undo::redo

bind .t <Return> {gui_enter}

proc create_hist {} {
	global histsql
	if {![winfo exists .hist]} {
		toplevel .hist
		ttk::frame .hist.f
		wm title .hist "Sheet Music Database: Undo History"

		ttk::button .hist.f.undo -text "Undo" -command ::undo::undo -state disabled
		ttk::button .hist.f.redo -text "Redo" -command ::undo::redo -state disabled
		text .hist.f.tbox -height 16
		.hist.f.tbox insert end $histsql

		pack .hist.f

		grid .hist.f.undo .hist.f.redo
		grid .hist.f.tbox -columnspan 2
	}
}

proc gui_enter {} {
	global histsql
	set histsql [string cat $histsql [addrow]]
	.t.erow.name delete 0 end
	::undo::event
	if {[winfo exists .hist]} {
		# Update the fake undo history
		.hist.f.tbox replace 0.0 end $histsql
	}
	puts $histsql
}

proc addrow {} {
	global histsql
	# Get our values as Tcl variables for sqlite's eval command
	set title [.t.erow.title get]
	set author [.t.erow.author get]
	set instrument [.t.erow.instrument get]
	set duet [expr {[lsearch [.t.erow.duet state] "selected"] >= 0}]
	set name [.t.erow.name get]
	
	set book ""
	set tune ""
	set ret ""

	if {[string length $title] > 0 && [string length $author] > 0} {
		set book [db eval {SELECT id FROM books WHERE title = $title AND author = $author}]
		# If the book exists, book should now have a single element.
		switch [llength $book] {
			0 {
				# Create a new book
				set bookcreate {INSERT INTO books VALUES(NULL, $title, $author, $instrument, $duet)}
				db eval $bookcreate
				set ret [string cat $ret [subst $bookcreate] ";\n"]
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
				set tunecreate {INSERT INTO tunes VALUES(NULL, $name)}
				db eval $tunecreate
				set ret [string cat $ret [subst $tunecreate] ";\n"]
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
		if {![db exists {SELECT 1 FROM book2tune WHERE bookid=$book AND tuneid=$tune}]} {
			set b2tcreate {INSERT INTO book2tune VALUES(NULL, $book, $tune)}
			db eval $b2tcreate
			set ret [string cat $ret [subst $b2tcreate] ";\n"]
		} else {
			puts "warning: tried to re-add existing relationship between book $book and tune $tune"
		}
	}
	return [string cat $ret "----\n"]
}
