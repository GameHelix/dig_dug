package db

// A write that was interrupted after its transaction had begun writing to the file (a crash,
// or Ctrl-C once the change no longer fitted in memory) leaves a hot journal beside it:
// <file>-journal, holding the pages as they were before the transaction. SQLite rolls such a
// journal back before the next read, but only on a connection that may write; a read-only
// connection fails with SQLITE_READONLY_ROLLBACK instead.

import (
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"os"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

// RecoveredMessage says that Recover rolled back an interrupted write in the file at path.
func RecoveredMessage(path string) string {
	return fmt.Sprintf("recovered an interrupted write: SQLite rolled %s back to its last commit with the journal the write left (%s-journal)", path, path)
}

// Recover rolls back the hot journal an interrupted write left beside the file at path, if
// there is one, and reports whether it did. It opens the file read-write once and reads from
// it, which makes SQLite roll the journal back, and closes it again. A journal that belongs to
// a write still under way is left alone.
func Recover(path string) (bool, error) {
	journal := path + "-journal"
	if info, err := os.Stat(journal); err != nil || info.Size() == 0 {
		return false, nil
	}
	d, err := connect(path)
	if err != nil {
		return false, fmt.Errorf("rolling back %s: %w", journal, err)
	}
	var n int
	err = d.QueryRow(`SELECT count(*) FROM sqlite_schema`).Scan(&n) // a read, in its own transaction
	if err := errors.Join(err, d.Close()); err != nil {
		return false, fmt.Errorf("rolling back %s: %w", journal, err)
	}
	_, err = os.Stat(journal)
	return errors.Is(err, fs.ErrNotExist), nil
}

// isReadOnlyRollback reports whether err is SQLite refusing to roll back a hot journal on a
// read-only connection.
func isReadOnlyRollback(err error) bool {
	var e *sqlite.Error
	return errors.As(err, &e) && e.Code() == sqlite3.SQLITE_READONLY_ROLLBACK
}

// probe reads from a connection, to find out whether it can.
func probe(d *sql.DB) error {
	var n int
	return d.QueryRow(`SELECT count(*) FROM sqlite_schema`).Scan(&n)
}
