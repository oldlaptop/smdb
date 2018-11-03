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

# Initialize undo history. hist is the stack of operations that have been
# committed to the database, and undun is the list of operations that have been
# popped from hist.
set hist {}
set undun {}

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

# Push an sql transaction onto the undo history. trans is a list of sql
# statements to be evaluated in the transaction, and undo is a list of sql
# statements that will reverse the transaction. trans is assumed to make at most
# one INSERT operation. Since the sql statements will be evaluated by sqlite3's
# eval command, they may refer to tcl variables; the only real use for this here
# is that the undo commands may refer to the special variable auto_id; this will
# be the saved value from last_insert_rowid after the original transaction was
# committed.
proc tpush {trans, undo} {
	puts "pushing `$trans` onto the undo history, reversible by `$undo`"
	do_trans $trans
	lappend hist [list trans undo [db last_insert_rowid]]
}

# Pop an sql transaction from the undo history, by executing the 'undo'
# transaction that was pushed with it. Returns the transaction popped.
proc tpop {} {
	set elem [lindex $hist end]
	set trans [lindex $elem 0]
	set undo [lindex $elem 1]
	set auto_id [lindex $elem 2]

	puts "popping `$trans` from the undo history with `undo` (id $auto_id)"
	do_trans $undo $auto_id

	set hist [lreplace $hist end end]
	lappend undun elem
	return $elem
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
