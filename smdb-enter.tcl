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

tk appname "smdb-enter"
wm title . "Sheet Music Database: Update"

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

ttk::frame .erow

ttk::label .erow.titlel -text "Book Title"
ttk::label .erow.authorl -text "Book Author"
ttk::label .erow.instrumentl -text "Book Instrument"
ttk::label .erow.duetl -text "Duets?"
ttk::label .erow.namel -text "Hymn Tune"

ttk::entry .erow.title
ttk::entry .erow.author
ttk::combobox .erow.instrument -state readonly -values {organ piano}
ttk::checkbutton .erow.duet
ttk::entry .erow.name
ttk::button .erow.enter -text Enter -command gui_enter -takefocus 0

pack .erow

grid .erow.titlel .erow.authorl .erow.instrumentl .erow.duetl .erow.namel
grid .erow.title .erow.author .erow.instrument .erow.duet .erow.name .erow.enter

foreach widget [winfo children .erow] {
	grid configure $widget -padx 4 -pady 4
}

.erow.instrument set organ

bind . <Return> {gui_enter}

proc gui_enter {} {
	addrow
	.erow.name delete 0 end
}

proc addrow {} {
	# Get our values as Tcl variables for sqlite's eval command
	set title [.erow.title get]
	set author [.erow.author get]
	set instrument [.erow.instrument get]
	set duet [expr {[lsearch [.erow.duet state] "selected"] >= 0}]
	set name [.erow.name get]
	
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
		if {![db exists {SELECT 1 FROM book2tune WHERE bookid=$book AND tuneid=$tune}]} {
			db eval {INSERT INTO book2tune VALUES(NULL, $book, $tune)}
		} else {
			puts "warning: tried to re-add existing relationship between book $book and tune $tune"
		}
	}
}
