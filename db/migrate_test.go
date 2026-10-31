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
	"strings"
	"testing"
)

// The schema of version 3, as it was before version 4.
//
//go:embed testdata/schema_v3.sql
var schemaV3 string

// v3File makes a version 3 database with rows in every table the migration to version 4
// changes, in the tables that hang from them, and in your data.
func v3File(t *testing.T, extra ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "v3.sqlite")
	lesson := func(uuid, typ string, position int) string {
		return `INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
			VALUES ('` + uuid + `', 'ch1', ` + string(rune('0'+position)) + `, '` + uuid + `', 'Lesson ` + uuid + `', '` + typ + `', 1, 10, 'Read me.',
			'2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`
	}
	raw(t, path, append([]string{
		schemaV3,
		`INSERT INTO course VALUES ('c1', 'learn-ci-cd', 'Learn CI/CD', 'Course', 'Short.', 'Long.', 0)`,
		`INSERT INTO course VALUES ('c2', 'learn-logging', 'Learn Logging', 'Course', 'Short.', 'Long.', 1)`,
		`INSERT INTO chapter VALUES ('ch1', 'c1', 0, '1-deploy', 'Deploy', 'Ship it.')`,
		lesson("deploy", "type_cli", 0), lesson("local", "type_cli", 1), lesson("none", "type_cli", 2), lesson("quiz", "type_choice", 3),
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
	}, extra...)...)
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

func TestMigrateFrom3(t *testing.T) {
	path := v3File(t)
	before, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	kept := dump(t, before, "cli_lesson")
	before.Close()

	d, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var version int
	d.QueryRow(`PRAGMA user_version`).Scan(&version)
	if version != 4 {
		t.Fatalf("user_version = %d after the migration", version)
	}
	if got := dump(t, d, "cli_lesson", "server_address"); got != kept {
		t.Errorf("rows changed:\nbefore\n%s\nafter\n%s", kept, got)
	}
	for _, tc := range []struct {
		uuid, base string
		asks       int
	}{
		{"deploy", "NULL", 1},
		{"local", "http://localhost:8080", 0},
		{"none", "NULL", 0},
	} {
		var base string
		var asks, agent, complete int
		if err := d.QueryRow(`SELECT coalesce(base_url_default, 'NULL'), asks_for_base_url, use_agent_prompt, contains_complete_dir FROM cli_lesson WHERE lesson_uuid = ?`, tc.uuid).
			Scan(&base, &asks, &agent, &complete); err != nil {
			t.Fatal(err)
		}
		if base != tc.base || asks != tc.asks {
			t.Errorf("%s: base_url_default %s, asks_for_base_url %d; want %s, %d", tc.uuid, base, asks, tc.base, tc.asks)
		}
	}
	if p, err := Validate(context.Background(), d); err != nil || len(p) > 0 {
		t.Error(p, err)
	}

	// The migrated file has the schema of a new one.
	fresh, err := Create(filepath.Join(t.TempDir(), "v4.sqlite"))
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

	// And it holds to version 4's rules.
	for _, tc := range []struct {
		stmt string
		ok   bool
	}{
		{`UPDATE cli_lesson SET base_url_default = 'override' WHERE lesson_uuid = 'none'`, false},
		{`UPDATE cli_lesson SET base_url_default = 'http://localhost:9090' WHERE lesson_uuid = 'deploy'`, false},
		{`UPDATE cli_lesson SET asks_for_base_url = 2 WHERE lesson_uuid = 'none'`, false},
		{`UPDATE project SET dir = NULL, base_url = NULL WHERE course_uuid = 'c2'`, false},
		{`UPDATE project SET dir = NULL WHERE course_uuid = 'c1'`, true},
		{`INSERT INTO server_address VALUES ('http://localhost:3000', 'http://localhost:3300')`, true},
		{`INSERT INTO server_address VALUES ('http://localhost:3000', 'http://localhost:3301')`, false},
		{`INSERT INTO project VALUES ('nowhere', '/tmp/x', NULL)`, false},
	} {
		_, err := d.Exec(tc.stmt)
		if (err == nil) != tc.ok {
			t.Errorf("%s: err = %v, want ok = %v", tc.stmt, err, tc.ok)
		}
	}
}

// A migration that would break a foreign key changes nothing.
func TestMigrationRollsBack(t *testing.T) {
	path := v3File(t, `PRAGMA foreign_keys = OFF`, `INSERT INTO project VALUES ('no-such-course', '/Users/me/x', NULL)`)
	before, _ := os.ReadFile(path)
	if d, err := Open(path); err == nil {
		d.Close()
		t.Fatal("Open migrated a file with a foreign key pointing nowhere")
	} else if !strings.Contains(err.Error(), "foreign keys pointing nowhere") {
		t.Errorf("err = %v", err)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("the failed migration changed the file")
	}
}

func TestTableDefinition(t *testing.T) {
	for _, table := range []string{"cli_lesson", "project", "server_address", "lesson"} {
		def, err := tableDefinition(table)
		if err != nil || !strings.HasPrefix(def, "CREATE TABLE "+table+" (") || !strings.HasSuffix(strings.TrimSpace(def), "STRICT") {
			t.Errorf("tableDefinition(%s) = %q, %v", table, def, err)
		}
	}
	if _, err := tableDefinition("nothing"); err == nil {
		t.Error("tableDefinition of a missing table should fail")
	}
}
