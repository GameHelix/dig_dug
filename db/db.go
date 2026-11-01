// Package db creates, opens, checks and migrates Gopherwood libraries: SQLite files whose tables
// are db/schema.sql, embedded here.
package db

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	_ "modernc.org/sqlite" // the pure-Go SQLite driver, registered as "sqlite"
)

// Schema is db/schema.sql. It makes a new, empty database and is never run against an
// existing one.
//
//go:embed schema.sql
var Schema string

// Version is the schema version, and ApplicationID the mark of a Gopherwood database, as
// schema.sql sets them with PRAGMA user_version and PRAGMA application_id.
var (
	Version       = pragmaValue(Schema, "user_version")
	ApplicationID = pragmaValue(Schema, "application_id")
)

// ErrNotFound is returned by Open for a file that does not exist.
var ErrNotFound = errors.New("no database file")

func pragmaValue(schema, name string) int {
	m := regexp.MustCompile(`(?im)^\s*PRAGMA\s+` + name + `\s*=\s*(\d+)\s*;`).FindStringSubmatch(schema)
	if m == nil {
		panic("db: schema.sql does not set " + name)
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		panic("db: bad " + name + " in schema.sql: " + m[1])
	}
	return n
}

// Create makes a new, empty library at path from schema.sql, creating its folder if needed.
// Nothing may exist at path yet.
func Create(path string) (*sql.DB, error) {
	if _, err := os.Lstat(path); err == nil {
		return nil, fmt.Errorf("creating %s: something already exists there", path)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("creating %s: %w", path, err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", path, err)
	}
	d, err := connect(path)
	if err != nil {
		return nil, err
	}
	if err := create(d); err != nil {
		d.Close()
		return nil, fmt.Errorf("creating %s: %w", path, err)
	}
	return d, nil
}

// Open opens the existing database at path. It must be a Gopherwood database. One of an older
// schema version is migrated to this program's, one version at a time, each step in one
// transaction (migrate.go); a newer one, or one no migration reaches, is refused and left as
// it is.
func Open(path string) (*sql.DB, error) {
	info, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("opening %s: %w", path, ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	if info.IsDir() {
		return nil, fmt.Errorf("opening %s: it is a folder", path)
	}
	// SQLite would roll back an interrupted write on its own here; doing it first says so.
	if recovered, err := Recover(path); err != nil {
		return nil, err
	} else if recovered {
		log.Print(RecoveredMessage(path))
	}
	d, err := connect(path)
	if err != nil {
		return nil, err
	}
	if err := upgrade(d); err != nil {
		d.Close()
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	return d, nil
}

// Inspect opens the existing file at path to read it as it is: read-only, without the checks
// and migrations Open makes, so that Validate can say what is wrong with any file instead of
// refusing it. Nothing is written through it. An interrupted write is the one thing set right
// first: a read-only connection cannot read past the journal it left, so Inspect has SQLite
// roll it back (Recover) and reports that it did.
func Inspect(path string) (d *sql.DB, recovered bool, err error) {
	info, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, fmt.Errorf("opening %s: %w", path, ErrNotFound)
	}
	if err != nil {
		return nil, false, fmt.Errorf("opening %s: %w", path, err)
	}
	if info.IsDir() {
		return nil, false, fmt.Errorf("opening %s: it is a folder", path)
	}
	if recovered, err = Recover(path); err != nil {
		return nil, false, err
	}
	if d, err = readOnly(path); err != nil {
		return nil, recovered, err
	}
	if err := probe(d); isReadOnlyRollback(err) { // a journal left between Recover and now
		d.Close()
		again, err := Recover(path)
		if err != nil {
			return nil, recovered, err
		}
		recovered = recovered || again
		if d, err = readOnly(path); err != nil {
			return nil, recovered, err
		}
	}
	return d, recovered, nil // a file SQLite cannot read at all is for Validate to report
}

// readOnly opens a read-only connection pool on the file at path.
func readOnly(path string) (*sql.DB, error) {
	q := url.Values{}
	q.Set("mode", "ro")
	q.Add("_pragma", "busy_timeout(10000)")
	u := url.URL{Scheme: "file", Path: path, RawQuery: q.Encode()}
	if !filepath.IsAbs(path) {
		u = url.URL{Scheme: "file", Opaque: (&url.URL{Path: path}).EscapedPath(), RawQuery: q.Encode()}
	}
	d, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	d.SetMaxOpenConns(1)
	return d, nil
}

// connect opens a connection pool on path in which every connection has foreign keys on and
// uses the rollback journal (journal_mode DELETE, never WAL), so the file is whole, and safe
// to commit, whenever no write is under way. The pool holds a single connection: with a
// rollback journal, a second connection of the same process that is still reading would only
// block the first one's writes.
func connect(path string) (*sql.DB, error) {
	if strings.ContainsRune(path, '?') {
		return nil, fmt.Errorf("database path %q must not contain '?'", path)
	}
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(10000)")
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "journal_mode(DELETE)")
	q.Add("_pragma", "synchronous(FULL)")
	q.Set("_txlock", "immediate") // take the write lock at BEGIN, so a transaction never waits halfway
	d, err := sql.Open("sqlite", path+"?"+q.Encode())
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	d.SetMaxOpenConns(1)
	if err := d.Ping(); err != nil {
		d.Close()
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	return d, nil
}

// upgrade checks that the file is a Gopherwood database of this schema version, and migrates
// it if it is older and every migration it needs exists.
func upgrade(d *sql.DB) error {
	var mode string
	if err := d.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil {
		return err
	}
	if !strings.EqualFold(mode, "delete") {
		return fmt.Errorf("journal mode is %s, want delete", mode)
	}
	var app, version int
	if err := d.QueryRow(`SELECT (SELECT application_id FROM pragma_application_id), (SELECT user_version FROM pragma_user_version)`).Scan(&app, &version); err != nil {
		return err
	}
	switch {
	case app != ApplicationID:
		return fmt.Errorf("not a Gopherwood database (application_id %d)", app)
	case version > Version:
		return fmt.Errorf("the database is schema version %d, newer than this program's %d; update the program", version, Version)
	}
	for v := version; v < Version; v++ {
		if migrations[v] == nil {
			return fmt.Errorf("the database is schema version %d and no migration takes version %d to %d", version, v, v+1)
		}
	}
	for v := version; v < Version; v++ {
		if err := migrate(context.Background(), d, v); err != nil {
			return err
		}
	}
	return nil
}

// create runs schema.sql on an empty database, in one transaction.
func create(d *sql.DB) error {
	var objects int
	if err := d.QueryRow(`SELECT count(*) FROM sqlite_schema`).Scan(&objects); err != nil {
		return err
	}
	if objects > 0 {
		return errors.New("the database is not empty")
	}
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(Schema); err != nil {
		return fmt.Errorf("schema.sql: %w", err)
	}
	return tx.Commit()
}
