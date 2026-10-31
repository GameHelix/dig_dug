package db

import (
	"bytes"
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// The schemas of versions 3 and 4, as they were before the versions after them.
var (
	//go:embed testdata/schema_v3.sql
	schemaV3 string
	//go:embed testdata/schema_v4.sql
	schemaV4 string
)

// interviews are three interview lessons in chapter ch1, from position 4 on, whose acceptance
// criteria are empty, blank and real; a real value is kept exactly, blanks around it included.
var interviews = []string{
	oldLesson("talk-empty", "type_interview_chat", 4), oldLesson("talk-blank", "type_interview_chat", 5), oldLesson("talk-real", "type_interview_chat", 6),
	`INSERT INTO interview_lesson VALUES ('talk-empty', 'type_interview_chat', 'Explain table tests.', '')`,
	`INSERT INTO interview_lesson VALUES ('talk-blank', 'type_interview_chat', 'Explain subtests.', ' ' || char(9, 10) || ' ')`,
	`INSERT INTO interview_lesson VALUES ('talk-real', 'type_interview_chat', 'Explain fuzzing.', '  Mentions go test -fuzz.' || char(10))`,
}

const realCriteria = "  Mentions go test -fuzz.\n"

func oldLesson(uuid, typ string, position int) string {
	return `INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
		VALUES ('` + uuid + `', 'ch1', ` + string(rune('0'+position)) + `, '` + uuid + `', 'Lesson ` + uuid + `', '` + typ + `', 1, 10, 'Read me.',
		'2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`
}

// criteria returns each interview lesson's acceptance_criteria, "NULL" for NULL.
func criteria(t *testing.T, d *sql.DB) map[string]string {
	t.Helper()
	rows, err := d.Query(`SELECT lesson_uuid, coalesce(acceptance_criteria, 'NULL') FROM interview_lesson`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var u, c string
		rows.Scan(&u, &c)
		out[u] = c
	}
	return out
}

func checkCriteria(t *testing.T, d *sql.DB) {
	t.Helper()
	got := criteria(t, d)
	for u, want := range map[string]string{"talk-empty": "NULL", "talk-blank": "NULL", "talk-real": realCriteria} {
		if got[u] != want {
			t.Errorf("%s: acceptance_criteria %q, want %q", u, got[u], want)
		}
	}
}

// v4File makes a version 4 database with rows in the table the migration to version 5
// changes, in the tables version 4 brought, and in your data.
func v4File(t *testing.T, extra ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "v4.sqlite")
	stmts := []string{
		schemaV4,
		`INSERT INTO course VALUES ('c1', 'learn-ci-cd', 'Learn CI/CD', 'Course', 'Short.', 'Long.', 0)`,
		`INSERT INTO chapter VALUES ('ch1', 'c1', 0, '1-deploy', 'Deploy', 'Ship it.')`,
		oldLesson("deploy", "type_cli", 0), oldLesson("quiz", "type_choice", 1),
		`INSERT INTO cli_lesson VALUES ('deploy', 'type_cli', NULL, 1, 0, 1)`,
		`INSERT INTO cli_step VALUES ('deploy', 0, 'http', 'Check the app.', 0, NULL)`,
		`INSERT INTO cli_http_request VALUES ('deploy', 0, 'http', 'GET', '${baseURL}/healthz', 1, NULL, NULL, NULL, NULL)`,
		`INSERT INTO quiz_lesson VALUES ('quiz', 'type_choice', 0)`,
		`INSERT INTO quiz_question VALUES ('quiz', 0, 'Why?')`,
		`INSERT INTO quiz_answer VALUES ('quiz', 0, 0, 'Because.', 1), ('quiz', 0, 1, 'No.', 0)`,
	}
	stmts = append(stmts, interviews...)
	stmts = append(stmts,
		`INSERT INTO progress VALUES ('talk-real', NULL, '2026-10-31T12:30:00Z')`,
		`INSERT INTO note VALUES ('talk-empty', 'Practice this one.', '2026-10-31T12:00:00Z')`,
		`INSERT INTO project VALUES ('c1', NULL, 'https://my-app.example.com')`,
		`INSERT INTO server_address VALUES ('http://localhost:3000', 'http://localhost:3300')`,
	)
	raw(t, path, append(stmts, extra...)...)
	return path
}

// v3File makes a version 3 database with rows in every table the migration to version 4
// changes, in the tables that hang from them, and in your data.
func v3File(t *testing.T, extra ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "v3.sqlite")
	raw(t, path, append(append([]string{
		schemaV3,
		`INSERT INTO course VALUES ('c1', 'learn-ci-cd', 'Learn CI/CD', 'Course', 'Short.', 'Long.', 0)`,
		`INSERT INTO course VALUES ('c2', 'learn-logging', 'Learn Logging', 'Course', 'Short.', 'Long.', 1)`,
		`INSERT INTO chapter VALUES ('ch1', 'c1', 0, '1-deploy', 'Deploy', 'Ship it.')`,
		oldLesson("deploy", "type_cli", 0), oldLesson("local", "type_cli", 1), oldLesson("none", "type_cli", 2), oldLesson("quiz", "type_choice", 3),
		`INSERT INTO cli_lesson VALUES ('deploy', 'type_cli', 'override', 0, 1)`,
		`INSERT INTO cli_lesson VALUES ('local', 'type_cli', 'http://localhost:8080', 1, 0)`,
		`INSERT INTO cli_lesson VALUES ('none', 'type_cli', NULL, 0, 0)`,
		`INSERT INTO cli_lesson_os VALUES ('deploy', 'linux'), ('deploy', 'darwin'), ('local', 'darwin')`,
		`INSERT INTO cli_step VALUES ('deploy', 0, 'http', 'Check the app.', 0, NULL), ('local', 0, 'command', 'Run it.', 1, 1000), ('none', 0, 'command', 'List.', 0, NULL)`,
		`INSERT INTO cli_http_request VALUES ('deploy', 0, 'http', 'GET', '${baseURL}/healthz', 1, NULL, NULL, NULL, NULL)`,
		`INSERT INTO cli_http_test (lesson_uuid, step_position, position, kind, status_code) VALUES ('deploy', 0, 0, 'status_code', 200)`,
		`INSERT INTO cli_command VALUES ('local', 0, 'command', 'go run .', NULL), ('none', 0, 'command', 'ls', NULL)`,
		`INSERT INTO quiz_lesson VALUES ('quiz', 'type_choice', 0)`,
		`INSERT INTO quiz_question VALUES ('quiz', 0, 'Why?')`,
		`INSERT INTO quiz_answer VALUES ('quiz', 0, 0, 'Because.', 1), ('quiz', 0, 1, 'No.', 0)`,
		`INSERT INTO progress VALUES ('deploy', '2026-10-31T12:00:00Z', '2026-10-31T12:30:00Z')`,
		`INSERT INTO code_file VALUES ('local', 'main.go', 'package main', '2026-10-31T12:00:00Z')`,
		`INSERT INTO project VALUES ('c1', '/Users/me/ci', 'https://my-app.example.com')`,
		`INSERT INTO project VALUES ('c2', '/Users/me/logging', NULL)`,
		`INSERT INTO setting VALUES ('editor.font_size', '14')`,
	}, interviews...), extra...)...)
	return path
}

// dump renders every row of every table but the ones named, to see they did not change.
func dump(t *testing.T, d *sql.DB, skip ...string) string {
	t.Helper()
	var b strings.Builder
	for _, table := range tableNames(t, d) {
		if strings.HasPrefix(table, "lesson_search") || strings.Contains(" "+strings.Join(skip, " ")+" ", " "+table+" ") {
			continue
		}
		rows, err := d.Query(`SELECT * FROM ` + table + ` ORDER BY 1, 2`)
		if err != nil {
			t.Fatal(err)
		}
		cols, _ := rows.Columns()
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			rows.Scan(ptrs...)
			b.WriteString(table)
			for _, v := range vals {
				b.WriteString("|")
				b.WriteString(strings.TrimSpace(strings.ReplaceAll(sprint(v), "\n", " ")))
			}
			b.WriteString("\n")
		}
		rows.Close()
	}
	return b.String()
}

func sprint(v any) string {
	switch v := v.(type) {
	case nil:
		return "NULL"
	case []byte:
		return string(v)
	default:
		return fmt.Sprint(v)
	}
}

func tableNames(t *testing.T, d *sql.DB) []string {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		rows.Scan(&n)
		out = append(out, n)
	}
	return out
}

var reQuotedTable = regexp.MustCompile(`^CREATE TABLE "([^"]+)"`)

// schemaOf returns every object of the database's schema with its SQL, without comments and
// with spaces collapsed. A table rebuilt by ALTER TABLE ... RENAME has its name quoted.
func schemaOf(t *testing.T, d *sql.DB) map[string]string {
	t.Helper()
	rows, err := d.Query(`SELECT type, name, coalesce(sql, '') FROM sqlite_schema`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var typ, name, text string
		rows.Scan(&typ, &name, &text)
		var b strings.Builder
		for _, line := range strings.Split(text, "\n") {
			line, _, _ = strings.Cut(line, "--")
			b.WriteString(line + " ")
		}
		out[typ+" "+name] = reQuotedTable.ReplaceAllString(strings.Join(strings.Fields(b.String()), " "), "CREATE TABLE $1")
	}
	return out
}

// sameSchema fails unless d has the schema of a new database, comments aside.
func sameSchema(t *testing.T, d *sql.DB) {
	t.Helper()
	fresh, err := Create(filepath.Join(t.TempDir(), "new.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	got, want := schemaOf(t, d), schemaOf(t, fresh)
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s:\n got %s\nwant %s", k, got[k], w)
		}
	}
	for k := range got {
		if _, ok := want[k]; !ok {
			t.Errorf("%s is left over", k)
		}
	}
}

// migrated opens an old file, which migrates it, and checks what every migration must leave:
// the current version, the rows of the tables it does not change, the library checks passed
// and the schema of a new database.
func migrated(t *testing.T, path string, changed ...string) *sql.DB {
	t.Helper()
	before, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	kept := dump(t, before, changed...)
	skip := changed
	if !slices.Contains(tableNames(t, before), "server_address") {
		skip = append(skip, "server_address") // new in version 4
	}
	before.Close()
	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	var version int
	d.QueryRow(`PRAGMA user_version`).Scan(&version)
	if version != Version {
		t.Fatalf("user_version = %d after migrating, want %d", version, Version)
	}
	if got := dump(t, d, skip...); got != kept {
		t.Errorf("rows changed:\nbefore\n%s\nafter\n%s", kept, got)
	}
	if p, err := Validate(context.Background(), d); err != nil || len(p) > 0 {
		t.Error(p, err)
	}
	sameSchema(t, d)
	return d
}

// Version 3 goes to 4 and then to 5, each step in its own transaction.
func TestMigrateFrom3(t *testing.T) {
	d := migrated(t, v3File(t), "cli_lesson", "interview_lesson")
	for _, tc := range []struct {
		uuid, base string
		asks       int
	}{
		{"deploy", "NULL", 1},
		{"local", "http://localhost:8080", 0},
		{"none", "NULL", 0},
	} {
		var base string
		var asks int
		if err := d.QueryRow(`SELECT coalesce(base_url_default, 'NULL'), asks_for_base_url FROM cli_lesson WHERE lesson_uuid = ?`, tc.uuid).Scan(&base, &asks); err != nil {
			t.Fatal(err)
		}
		if base != tc.base || asks != tc.asks {
			t.Errorf("%s: base_url_default %s, asks_for_base_url %d; want %s, %d", tc.uuid, base, asks, tc.base, tc.asks)
		}
	}
	checkCriteria(t, d)
	rules(t, d)
}

func TestMigrateFrom4(t *testing.T) {
	d := migrated(t, v4File(t), "interview_lesson")
	checkCriteria(t, d)
	rules(t, d)
}

// rules checks that a migrated file holds to the current version's rules.
func rules(t *testing.T, d *sql.DB) {
	t.Helper()
	for _, tc := range []struct {
		stmt string
		ok   bool
	}{
		{`UPDATE cli_lesson SET base_url_default = 'override' WHERE lesson_uuid = 'deploy'`, false},
		{`UPDATE cli_lesson SET base_url_default = 'http://localhost:9090' WHERE lesson_uuid = 'deploy'`, false},
		{`UPDATE cli_lesson SET asks_for_base_url = 2 WHERE lesson_uuid = 'deploy'`, false},
		{`UPDATE project SET dir = NULL, base_url = NULL WHERE course_uuid = 'c1'`, false},
		{`UPDATE project SET dir = NULL WHERE course_uuid = 'c1'`, true},
		{`INSERT INTO server_address VALUES ('http://localhost:16686', 'http://localhost:16687')`, true},
		{`INSERT INTO server_address VALUES ('http://localhost:16686', 'http://localhost:16688')`, false},
		{`INSERT INTO project VALUES ('nowhere', '/tmp/x', NULL)`, false},
		{`UPDATE interview_lesson SET acceptance_criteria = '' WHERE lesson_uuid = 'talk-real'`, false},
		{`UPDATE interview_lesson SET acceptance_criteria = NULL WHERE lesson_uuid = 'talk-real'`, true},
	} {
		_, err := d.Exec(tc.stmt)
		if (err == nil) != tc.ok {
			t.Errorf("%s: err = %v, want ok = %v", tc.stmt, err, tc.ok)
		}
	}
}

// A migration that would break a foreign key changes nothing, from either version.
func TestMigrationRollsBack(t *testing.T) {
	for name, path := range map[string]string{
		"version 3": v3File(t, `PRAGMA foreign_keys = OFF`, `INSERT INTO project VALUES ('no-such-course', '/Users/me/x', NULL)`),
		"version 4": v4File(t, `PRAGMA foreign_keys = OFF`, `INSERT INTO note VALUES ('no-such-lesson', 'Lost.', '2026-10-31T12:00:00Z')`),
	} {
		before, _ := os.ReadFile(path)
		if d, err := Open(path); err == nil {
			d.Close()
			t.Errorf("%s: Open migrated a file with a foreign key pointing nowhere", name)
		} else if !strings.Contains(err.Error(), "foreign keys pointing nowhere") {
			t.Errorf("%s: err = %v", name, err)
		}
		if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
			t.Errorf("%s: the failed migration changed the file", name)
		}
	}
}

func TestTableDefinition(t *testing.T) {
	for _, table := range []string{"cli_lesson", "project", "server_address", "interview_lesson", "lesson"} {
		def, err := tableDefinition(table)
		if err != nil || !strings.HasPrefix(def, "CREATE TABLE "+table+" (") || !strings.HasSuffix(strings.TrimSpace(def), "STRICT") {
			t.Errorf("tableDefinition(%s) = %q, %v", table, def, err)
		}
	}
	if _, err := tableDefinition("nothing"); err == nil {
		t.Error("tableDefinition of a missing table should fail")
	}
}
