// Package db creates, opens and checks Gopherwood's database, data/gopherwood.sqlite in this
// repository. Its tables are db/schema.sql, embedded here.
package db

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"io/fs"
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

// RelPath is where the database lives inside the repository.
const RelPath = "data/gopherwood.sqlite"

// module is the module path in the repository's go.mod, which marks its root.
const module = "github.com/jobloom/gopherwood"

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

// Path returns the database file of the repository that holds dir: data/gopherwood.sqlite
// under the nearest folder, dir or one above it, whose go.mod declares this module.
func Path(dir string) (string, error) {
	start, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("finding the repository: %w", err)
	}
	for d := start; ; d = filepath.Dir(d) {
		if isRoot(d) {
			return filepath.Join(d, filepath.FromSlash(RelPath)), nil
		}
		if filepath.Dir(d) == d {
			return "", fmt.Errorf("%s is not inside the gopherwood repository (no go.mod of module %s above it)", start, module)
		}
	}
}

func isRoot(dir string) bool {
	b, err := os.ReadFile(filepath.Join(dir, "go.mod"))
	if err != nil {
		return false
	}
	for line := range strings.SplitSeq(string(b), "\n") {
		if f := strings.Fields(line); len(f) >= 2 && f[0] == "module" {
			return strings.Trim(f[1], `"`) == module
		}
	}
	return false
}

// Create makes a new database at path from schema.sql, creating its folder if needed. The file
// must not exist yet, or be empty.
func Create(path string) (*sql.DB, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > 0 {
		return nil, fmt.Errorf("creating %s: the file already exists", path)
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
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
