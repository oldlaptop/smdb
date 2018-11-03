#! /usr/bin/env wish

package require sqlite3

sqlite3 db "music.sqlite"

db eval {CREATE TABLE IF NOT EXISTS tunes (id INTEGER PRIMARY KEY ASC AUTOINCREMENT,
                                           name TEXT ASC)}
db eval {CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY ASC AUTOINCREMENT,
                                           title TEXT ASC,
                                           author TEXT ASC)}
db eval {CREATE TABLE IF NOT EXISTS books2tunes (id INTEGER PRIMARY KEY ASC AUTOINCREMENT,
                                                 bookid INTEGER REFERENCES books(id),
                                                 tuneid INTEGER REFERENCES tunes(id))}
db eval {PRAGMA foreign_keys=ON}

tk appname "smdb-enter"
wm title . "Sheet Music Database: Update"

ttk::frame .erow

ttk::label .erow.titlel -text "Book Title"
ttk::label .erow.authorl -text "Book Author"
ttk::label .erow.namel -text "Hymn Tune"

ttk::entry .erow.title
ttk::entry .erow.author
ttk::entry .erow.name
ttk::button .erow.enter -text Enter -command addrow

pack .erow

grid .erow.titlel .erow.authorl .erow.namel
grid .erow.title .erow.author .erow.name .erow.enter

foreach widget [winfo children .erow] {
	grid configure $widget -padx 4 -pady 4
}

bind . <Return> {addrow}

# Execute a list of sql statements as a single transaction.
proc do_trans {trans {auto_id -1}} {
	db transaction {
		foreach stmt $trans {
			db eval $stmt
		}
	}
}

proc addrow {} {
	# Get our values as Tcl variables for sqlite's eval command
	set title [.erow.title get]
	set author [.erow.author.get]
	set name [.erow.name.get]

	set book [db eval {SELECT id FROM books WHERE title = $title}]

	# If the book exists, book should now have a single element.
	switch [llength book]
	{
		0 {
			# Create a new book
			tpush {INSERT INTO books VALUES(NULL, $name
			
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
}
