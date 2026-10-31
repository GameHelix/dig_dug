package db

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newDB(t *testing.T) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "data", "gopherwood.sqlite")
	d, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d, path
}

// raw runs statements on the file without the settings Open and Create make, foreign keys
// included, to build the broken databases the checks must catch.
func raw(t *testing.T, path string, stmts ...string) {
	t.Helper()
	d, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	d.SetMaxOpenConns(1) // so a pragma holds for the statements after it
	for _, s := range stmts {
		if _, err := d.Exec(s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
}

func TestCreate(t *testing.T) {
	d, _ := newDB(t)
	for _, tc := range []struct {
		query string
		want  string
	}{
		{`PRAGMA journal_mode`, "delete"},
		{`PRAGMA foreign_keys`, "1"},
		{`PRAGMA user_version`, "4"},
		{`PRAGMA application_id`, "1196447556"},
		{`SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('course', 'chapter', 'lesson', 'lesson_topic', 'code_lesson', 'starter_file', 'quiz_lesson', 'quiz_question', 'quiz_answer', 'cli_lesson', 'cli_step', 'cli_http_test', 'github_lesson', 'interview_lesson', 'progress', 'attempt', 'note', 'code_file', 'project', 'setting', 'server_address')`, "21"},
		{`SELECT count(*) FROM sqlite_schema WHERE type = 'trigger'`, "3"},
	} {
		var got string
		if err := d.QueryRow(tc.query).Scan(&got); err != nil {
			t.Fatalf("%s: %v", tc.query, err)
		}
		if !strings.EqualFold(got, tc.want) {
			t.Errorf("%s = %s, want %s", tc.query, got, tc.want)
		}
	}
	if Version != 4 || ApplicationID != 1196447556 {
		t.Errorf("Version, ApplicationID = %d, %d; want what schema.sql sets", Version, ApplicationID)
	}
	if err := Check(context.Background(), d); err != nil {
		t.Errorf("a new database fails its checks: %v", err)
	}
}

func TestCreateRefusesAnExistingFile(t *testing.T) {
	_, path := newDB(t)
	if d, err := Create(path); err == nil {
		d.Close()
		t.Fatal("Create overwrote an existing database")
	}
}

func TestOpen(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup []string // run on a new database before it is opened again
		ok    bool
	}{
		{name: "a database it made", ok: true},
		{name: "one left in WAL mode", setup: []string{`PRAGMA journal_mode = WAL`}, ok: true},
		{name: "an older schema no migration reaches", setup: []string{`PRAGMA user_version = 2`}},
		{name: "a newer schema", setup: []string{`PRAGMA user_version = 5`}},
		{name: "not a Gopherwood file", setup: []string{`PRAGMA application_id = 42`}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, path := newDB(t)
			d.Close()
			raw(t, path, tc.setup...)
			before, _ := os.ReadFile(path)
			d, err := Open(path)
			if err == nil {
				defer d.Close()
			}
			if (err == nil) != tc.ok {
				t.Fatalf("Open: err = %v, want ok = %v", err, tc.ok)
			}
			if !tc.ok {
				if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
					t.Error("a refused file was changed")
				}
				return
			}
			var mode string
			d.QueryRow(`PRAGMA journal_mode`).Scan(&mode)
			if mode != "delete" {
				t.Errorf("journal_mode = %s", mode)
			}
		})
	}
}

func TestOpenMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "none.sqlite")
	if _, err := Open(path); !errors.Is(err, ErrNotFound) {
		t.Errorf("Open of a missing file: err = %v, want ErrNotFound", err)
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("Open created the file")
	}
}

func TestOpenWritesNothing(t *testing.T) {
	d, path := newDB(t)
	d.Close()
	before, _ := os.ReadFile(path)
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := Check(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	d.Close()
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("opening and checking a database changed the file")
	}
	for _, suffix := range []string{"-journal", "-wal", "-shm"} {
		if _, err := os.Stat(path + suffix); err == nil {
			t.Errorf("%s left behind", path+suffix)
		}
	}
}

const (
	course  = `INSERT INTO course VALUES ('c1', 'learn-go', 'Learn Go', 'Course', 'Short.', 'Long.', 0)`
	chapter = `INSERT INTO chapter VALUES ('ch1', 'c1', 0, '1-intro', 'Intro', '')`
)

func lesson(uuid, typ string, position int) string {
	return `INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
		VALUES ('` + uuid + `', 'ch1', ` + string(rune('0'+position)) + `, '` + uuid + `', 'A lesson', '` + typ + `', 1, 10, 'Read me.',
		'2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`
}

func TestCheck(t *testing.T) {
	for _, tc := range []struct {
		name  string
		stmts []string
		want  string // in the error; "" for a database that passes
	}{
		{
			name:  "a whole quiz lesson",
			stmts: []string{lesson("l1", "type_choice", 0), `INSERT INTO quiz_lesson VALUES ('l1', 'type_choice', 0)`, `INSERT INTO quiz_question VALUES ('l1', 0, 'Why?')`, `INSERT INTO quiz_answer VALUES ('l1', 0, 0, 'Because.', 1)`, `INSERT INTO quiz_answer VALUES ('l1', 0, 1, 'No.', 0)`},
		},
		{
			name:  "a lesson without its per-type row",
			stmts: []string{lesson("l1", "type_choice", 0)},
			want:  "has 0 quiz_lesson rows",
		},
		{
			name:  "a quiz question without a right answer",
			stmts: []string{lesson("l1", "type_choice", 0), `INSERT INTO quiz_lesson VALUES ('l1', 'type_choice', 0)`, `INSERT INTO quiz_question VALUES ('l1', 0, 'Why?')`, `INSERT INTO quiz_answer VALUES ('l1', 0, 0, 'No.', 0)`},
			want:  "quiz without exactly one right answer: l1 question 0",
		},
		{
			name:  "a command step without its command",
			stmts: []string{lesson("l1", "type_cli", 0), `INSERT INTO cli_lesson VALUES ('l1', 'type_cli', NULL, 0, 0, 0)`, `INSERT INTO cli_step VALUES ('l1', 0, 'command', 'Run it.', 0, NULL)`},
			want:  "command-line step without its command or request: l1 step 0",
		},
		{
			name:  "progress for a lesson that is not there",
			stmts: []string{`PRAGMA foreign_keys = OFF`, `INSERT INTO progress VALUES ('nowhere', '2026-01-01T00:00:00Z', NULL)`},
			want:  "foreign key: progress",
		},
		{
			name: "a search index out of step",
			stmts: []string{lesson("l1", "type_interview_chat", 0), `INSERT INTO interview_lesson VALUES ('l1', 'type_interview_chat', 'Ask.', 'Answer.')`,
				`INSERT INTO lesson_search(lesson_search, rowid, title, readme) SELECT 'delete', id, title, readme FROM lesson`},
			want: "search index check",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, path := newDB(t)
			d.Close()
			raw(t, path, append([]string{course, chapter}, tc.stmts...)...)
			d, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer d.Close()
			err = Check(context.Background(), d)
			switch {
			case tc.want == "" && err != nil:
				t.Errorf("Check: %v", err)
			case tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)):
				t.Errorf("Check: err = %v, want it to say %q", err, tc.want)
			}
		})
	}
}

func TestPath(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module github.com/jobloom/gopherwood\n\ngo 1.25.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(root, "cmd", "sync")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := Path(sub)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, "data", "gopherwood.sqlite"); got != want {
		t.Errorf("Path = %s, want %s", got, want)
	}

	other := t.TempDir()
	os.WriteFile(filepath.Join(other, "go.mod"), []byte("module example.com/other\n"), 0o644)
	if _, err := Path(other); err == nil {
		t.Error("Path outside the repository should fail")
	}
}
