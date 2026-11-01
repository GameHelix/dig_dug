package main

// Every library in these tests is invented here: a small course about testing in Go, with one
// lesson of each type.

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jobloom/gopherwood/db"
)

func runCmd(t *testing.T, args ...string) (code int, out, errOut string) {
	t.Helper()
	var o, e bytes.Buffer
	code = run(context.Background(), args, &o, &e)
	return code, o.String(), e.String()
}

// exec runs statements on a file directly, without the checks the tool makes, to build the
// libraries the tests need.
func exec(t *testing.T, path string, stmts ...string) {
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

func lesson(uuid, chapter, typ string, position int) string {
	return `INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
		VALUES ('` + uuid + `', '` + chapter + `', ` + string(rune('0'+position)) + `, '` + uuid + `', 'Lesson ` + uuid + `', '` + typ + `', 1, 20,
		'# A lesson\n\nRead this first.', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`
}

// smallLibrary is an invented course with a lesson of every type.
var smallLibrary = []string{
	`PRAGMA foreign_keys = ON`,
	`INSERT INTO course VALUES ('c-test', 'learn-testing', 'Learn Testing', 'Course', 'Tests, from the start.', 'A small invented course.', 0)`,
	`INSERT INTO chapter VALUES ('ch-basics', 'c-test', 0, '1-basics', 'Basics', 'First steps.')`,
	`INSERT INTO chapter VALUES ('ch-tools', 'c-test', 1, '2-tools', 'Tools', 'The command line.')`,
	lesson("l-hello", "ch-basics", "type_code", 0),
	`INSERT INTO code_lesson VALUES ('l-hello', 'type_code', 'go', 'Hello, tests!' || char(10))`,
	`INSERT INTO starter_file VALUES ('l-hello', 'main.go', 0, 'package main', 0, 0)`,
	lesson("l-sum", "ch-basics", "type_code_tests", 1),
	`INSERT INTO code_lesson VALUES ('l-sum', 'type_code_tests', 'go', NULL)`,
	`INSERT INTO starter_file VALUES ('l-sum', 'sum.go', 0, 'package main', 0, 0), ('l-sum', 'sum_test.go', 1, 'package main', 0, 1)`,
	lesson("l-quiz", "ch-basics", "type_choice", 2),
	`INSERT INTO quiz_lesson VALUES ('l-quiz', 'type_choice', 0)`,
	`INSERT INTO quiz_question VALUES ('l-quiz', 0, 'Which functions does go test run?')`,
	`INSERT INTO quiz_answer VALUES ('l-quiz', 0, 0, 'Functions named TestXxx', 1), ('l-quiz', 0, 1, 'Every function', 0)`,
	lesson("l-shell", "ch-tools", "type_cli", 0),
	`INSERT INTO cli_lesson VALUES ('l-shell', 'type_cli', 'http://localhost:8080', 0, 0, 0)`,
	`INSERT INTO cli_lesson_os VALUES ('l-shell', 'darwin'), ('l-shell', 'linux')`,
	`INSERT INTO cli_step VALUES ('l-shell', 0, 'command', 'Print the Go version.', 0, NULL), ('l-shell', 1, 'http', 'Ask your server.', 0, NULL)`,
	`INSERT INTO cli_command VALUES ('l-shell', 0, 'command', 'go version', NULL)`,
	`INSERT INTO cli_command_test (lesson_uuid, step_position, position, kind, exit_code) VALUES ('l-shell', 0, 0, 'exit_code', 0)`,
	`INSERT INTO cli_http_request VALUES ('l-shell', 1, 'http', 'GET', '${baseURL}/health', 1, NULL, NULL, NULL, NULL)`,
	`INSERT INTO cli_http_test (lesson_uuid, step_position, position, kind, status_code) VALUES ('l-shell', 1, 0, 'status_code', 200)`,
	lesson("l-repo", "ch-tools", "type_github_checks", 1),
	`INSERT INTO github_lesson VALUES ('l-repo', 'type_github_checks', 0, 0)`,
	`INSERT INTO github_step (lesson_uuid, position, kind) VALUES ('l-repo', 0, 'repo_exists')`,
	lesson("l-talk", "ch-tools", "type_interview_chat", 2),
	`INSERT INTO interview_lesson VALUES ('l-talk', 'type_interview_chat', 'Explain table-driven tests.', 'Mentions t.Run.')`,
}

func newLibrary(t *testing.T, stmts ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	if code, _, errOut := runCmd(t, "create", path); code != 0 {
		t.Fatalf("create: %d %s", code, errOut)
	}
	exec(t, path, stmts...)
	return path
}

func TestCreateThenCheck(t *testing.T) {
	path := filepath.Join(t.TempDir(), "libraries", "empty.sqlite")
	code, out, errOut := runCmd(t, "create", path)
	if code != 0 || out != "created "+path+": an empty library of format 6\n" {
		t.Fatalf("create: %d %q %q", code, out, errOut)
	}
	code, out, _ = runCmd(t, "check", path)
	if code != 0 || !strings.HasPrefix(out, "ok: "+path+" is a library of format 6 with 0 courses, 0 chapters and 0 lessons") {
		t.Errorf("check of an empty library: %d %q", code, out)
	}

	empty := filepath.Join(t.TempDir(), "empty-file.sqlite")
	os.WriteFile(empty, nil, 0o644)
	for _, p := range []string{path, empty, t.TempDir()} {
		if code, _, errOut := runCmd(t, "create", p); code != 1 || !strings.Contains(errOut, "already exists") {
			t.Errorf("create over %s: %d %q", p, code, errOut)
		}
	}
}

func TestCheckSmallLibrary(t *testing.T) {
	path := newLibrary(t, smallLibrary...)
	before, _ := os.ReadFile(path)
	code, out, errOut := runCmd(t, "check", path)
	if code != 0 || !strings.Contains(out, "with 1 courses, 2 chapters and 6 lessons") {
		t.Errorf("check: %d %q %q", code, out, errOut)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("check changed the file")
	}
}

// Each rule of the format fails on a library broken for it, with one line per problem.
func TestCheckFindsEachProblem(t *testing.T) {
	for _, tc := range []struct {
		name    string
		breakIt []string // statements that break the small library
		want    []string // the lines check prints
	}{
		{
			name:    "another kind of file",
			breakIt: []string{`PRAGMA application_id = 7`},
			want:    []string{"application_id is 7, not 1196447556: the file is not a Gopherwood library"},
		},
		{
			name:    "an older format",
			breakIt: []string{`PRAGMA user_version = 3`},
			want:    []string{"user_version is 3, not 6: the library is of an older format; migrating brings it up to date"},
		},
		{
			name:    "a newer format",
			breakIt: []string{`PRAGMA user_version = 9`},
			want:    []string{"user_version is 9, not 6: the library is of a newer format than this program knows"},
		},
		{
			name:    "a note on a lesson that is not there",
			breakIt: []string{`PRAGMA foreign_keys = OFF`, `INSERT INTO note VALUES ('l-gone', 'My note.', '2026-01-01T00:00:00Z')`},
			want:    []string{"foreign key: note row 1 points at a missing lesson row"},
		},
		{
			name:    "a lesson without its per-type row",
			breakIt: []string{`DELETE FROM interview_lesson`},
			want:    []string{"lesson l-talk (type_interview_chat) has 0 interview_lesson rows, want 1"},
		},
		{
			name:    "a lesson with another type's row",
			breakIt: []string{`PRAGMA foreign_keys = OFF`, `INSERT INTO github_lesson VALUES ('l-talk', 'type_github_checks', 0, 0)`},
			want: []string{"foreign key: github_lesson row 2 points at a missing lesson row",
				"lesson l-talk (type_interview_chat) has 1 github_lesson rows, want 0"},
		},
		{
			name:    "a quiz question without its right answer",
			breakIt: []string{`UPDATE quiz_answer SET is_correct = 0`},
			want:    []string{"quiz question 0 of lesson l-quiz has 0 right answers, want 1"},
		},
		{
			name:    "a command step without its command",
			breakIt: []string{`DELETE FROM cli_command`},
			want:    []string{"cli_step 0 of lesson l-shell (command) has no cli_command row"},
		},
		{
			name:    "an HTTP step without its request",
			breakIt: []string{`DELETE FROM cli_http_request`},
			want:    []string{"cli_step 1 of lesson l-shell (http) has no cli_http_request row"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := newLibrary(t, append(smallLibrary, tc.breakIt...)...)
			before, _ := os.ReadFile(path)
			code, out, errOut := runCmd(t, "check", path)
			if code != 1 || errOut != "" {
				t.Fatalf("check: exit %d, stderr %q, want 1 and nothing", code, errOut)
			}
			if got := strings.Split(strings.TrimSuffix(out, "\n"), "\n"); strings.Join(got, "\n") != strings.Join(tc.want, "\n") {
				t.Errorf("check printed\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(tc.want, "\n"))
			}
			if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
				t.Error("check changed the file")
			}
		})
	}
}

func TestCheckDamagedAndForeignFiles(t *testing.T) {
	// A page overwritten as a failing disk might: every line comes from quick_check.
	path := newLibrary(t, smallLibrary...)
	d, _, err := db.Inspect(path)
	if err != nil {
		t.Fatal(err)
	}
	var root, size int64
	d.QueryRow(`SELECT (SELECT rootpage FROM sqlite_schema WHERE name = 'quiz_answer'), (SELECT page_size FROM pragma_page_size)`).Scan(&root, &size)
	d.Close()
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteAt(bytes.Repeat([]byte{0xff}, 16), (root-1)*size)
	f.Close()
	code, out, _ := runCmd(t, "check", path)
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if code != 1 || len(lines) == 0 {
		t.Fatalf("check of a damaged file: %d %q", code, out)
	}
	for _, l := range lines {
		if !strings.HasPrefix(l, "quick_check: ") {
			t.Errorf("line %q does not come from quick_check", l)
		}
	}

	notes := filepath.Join(t.TempDir(), "notes.sqlite")
	os.WriteFile(notes, []byte("Shopping: milk, eggs.\n"), 0o644)
	if code, out, _ := runCmd(t, "check", notes); code != 1 || !strings.HasPrefix(out, "the file is not an SQLite database SQLite can read: ") {
		t.Errorf("check of a text file: %d %q", code, out)
	}
	if code, _, errOut := runCmd(t, "check", filepath.Join(t.TempDir(), "missing.sqlite")); code != 1 || !strings.Contains(errOut, "no database file") {
		t.Errorf("check of a missing file: %d %q", code, errOut)
	}
}

// v3Library makes a library of format 3 from the schema kept in db/testdata: a course with a
// lesson that asks for the address of your own server, as format 3 wrote it ('override'), and
// a project for the course.
func v3Library(t *testing.T) string {
	t.Helper()
	schema, err := os.ReadFile(filepath.Join("..", "..", "db", "testdata", "schema_v3.sql"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "old.sqlite")
	exec(t, path,
		string(schema),
		`INSERT INTO course VALUES ('c-ship', 'learn-shipping', 'Learn Shipping', 'Course', 'Ship it.', 'An invented course about deploying.', 0)`,
		`INSERT INTO chapter VALUES ('ch-deploy', 'c-ship', 0, '1-deploy', 'Deploy', '')`,
		`INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
			VALUES ('l-deploy', 'ch-deploy', 0, '1-deploy', 'Deploy your app', 'type_cli', 1, 30, 'Deploy it.', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`,
		`INSERT INTO cli_lesson VALUES ('l-deploy', 'type_cli', 'override', 0, 0)`,
		`INSERT INTO cli_step VALUES ('l-deploy', 0, 'http', 'Ask the deployed app.', 0, NULL)`,
		`INSERT INTO cli_http_request VALUES ('l-deploy', 0, 'http', 'GET', '${baseURL}/healthz', 1, NULL, NULL, NULL, NULL)`,
		`INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
			VALUES ('l-review', 'ch-deploy', 1, '2-review', 'Review a deploy', 'type_interview_chat', 1, 20, 'Talk it through.', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`,
		`INSERT INTO interview_lesson VALUES ('l-review', 'type_interview_chat', 'Walk me through your last deploy.', '')`,
		`INSERT INTO project VALUES ('c-ship', '/Users/me/shipping', 'https://my-app.example.com')`,
	)
	return path
}

// v4Library makes a library of format 4 from the schema kept in db/testdata: an invented
// interview lesson whose acceptance criteria are empty, as format 4 stored them, and one with
// real criteria.
func v4Library(t *testing.T) string {
	t.Helper()
	schema, err := os.ReadFile(filepath.Join("..", "..", "db", "testdata", "schema_v4.sql"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "v4.sqlite")
	lesson := func(uuid string, position int) string {
		return `INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
			VALUES ('` + uuid + `', 'ch-talk', ` + string(rune('0'+position)) + `, '` + uuid + `', 'Interview ` + uuid + `', 'type_interview_chat', 1, 20, 'Talk it through.',
			'2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', NULL, '2026-01-03T00:00:00Z')`
	}
	exec(t, path,
		string(schema),
		`INSERT INTO course VALUES ('c-talk', 'learn-talking', 'Learn Talking', 'Course', 'Talk.', 'An invented course of mock interviews.', 0)`,
		`INSERT INTO chapter VALUES ('ch-talk', 'c-talk', 0, '1-talk', 'Talk', '')`,
		lesson("l-blank", 0), lesson("l-criteria", 1),
		`INSERT INTO interview_lesson VALUES ('l-blank', 'type_interview_chat', 'Describe a bug you fixed.', '')`,
		`INSERT INTO interview_lesson VALUES ('l-criteria', 'type_interview_chat', 'Describe a test you wrote.', 'Names what the test checks.')`,
	)
	return path
}

// criteria returns an interview lesson's acceptance_criteria, "NULL" for NULL.
func criteria(t *testing.T, path, uuid string) string {
	t.Helper()
	d, _, err := db.Inspect(path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var c string
	if err := d.QueryRow(`SELECT coalesce(acceptance_criteria, 'NULL') FROM interview_lesson WHERE lesson_uuid = ?`, uuid).Scan(&c); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestMigrateFrom4(t *testing.T) {
	path := v4Library(t)
	code, out, errOut := runCmd(t, "migrate", path)
	if code != 0 || !strings.HasPrefix(out, "migrated "+path+" from format 4 to 6\nok: ") {
		t.Fatalf("migrate: %d %q %q", code, out, errOut)
	}
	if got := criteria(t, path, "l-blank"); got != "NULL" {
		t.Errorf("empty criteria became %q, want NULL", got)
	}
	if got := criteria(t, path, "l-criteria"); got != "Names what the test checks." {
		t.Errorf("real criteria became %q", got)
	}
}

func TestMigrate(t *testing.T) {
	path := v3Library(t)
	if code, out, _ := runCmd(t, "check", path); code != 1 || !strings.HasPrefix(out, "user_version is 3, not 6") {
		t.Fatalf("check before migrating: %d %q", code, out)
	}
	code, out, errOut := runCmd(t, "migrate", path)
	if code != 0 || !strings.HasPrefix(out, "migrated "+path+" from format 3 to 6\nok: ") {
		t.Fatalf("migrate: %d %q %q", code, out, errOut)
	}
	d, _, err := db.Inspect(path)
	if err != nil {
		t.Fatal(err)
	}
	var version, asks int
	var base sql.NullString
	var dir, address string
	d.QueryRow(`SELECT (SELECT user_version FROM pragma_user_version), asks_for_base_url, base_url_default FROM cli_lesson WHERE lesson_uuid = 'l-deploy'`).Scan(&version, &asks, &base)
	d.QueryRow(`SELECT dir, base_url FROM project WHERE course_uuid = 'c-ship'`).Scan(&dir, &address)
	d.Close()
	if version != 6 || asks != 1 || base.Valid {
		t.Errorf("after migrating: user_version %d, asks_for_base_url %d, base_url_default %v", version, asks, base)
	}
	if dir != "/Users/me/shipping" || address != "https://my-app.example.com" {
		t.Errorf("the project became %q %q", dir, address)
	}
	if got := criteria(t, path, "l-review"); got != "NULL" {
		t.Errorf("empty criteria became %q after two steps, want NULL", got)
	}

	before, _ := os.ReadFile(path)
	if code, out, _ := runCmd(t, "migrate", path); code != 0 || out != path+" is already of format 6\n" {
		t.Errorf("migrating again: %d %q", code, out)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("migrating an up-to-date library changed it")
	}
}

func TestMigrateRefuses(t *testing.T) {
	newer := newLibrary(t, `PRAGMA user_version = 7`)
	other := filepath.Join(t.TempDir(), "other.sqlite")
	exec(t, other, `CREATE TABLE recipe (name TEXT)`)
	for _, tc := range []struct{ path, want string }{
		{newer, "newer than this program's 6"},
		{other, "is not a Gopherwood library"},
		{filepath.Join(t.TempDir(), "missing.sqlite"), "no database file"},
	} {
		before, _ := os.ReadFile(tc.path)
		if code, _, errOut := runCmd(t, "migrate", tc.path); code != 1 || !strings.Contains(errOut, tc.want) {
			t.Errorf("migrate %s: %d %q, want it to say %q", tc.path, code, errOut, tc.want)
		}
		if after, _ := os.ReadFile(tc.path); !bytes.Equal(before, after) {
			t.Errorf("a refused migration changed %s", tc.path)
		}
	}
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"check"}, {"frobnicate", "x.sqlite"}, {"check", "a", "b"}} {
		if code, _, errOut := runCmd(t, args...); code != 2 || !strings.Contains(errOut, "usage:") {
			t.Errorf("run %v: %d %q", args, code, errOut)
		}
	}
}

// crashEnv names, for the child process crash starts, the library to interrupt a write on.
const crashEnv = "GOPHERWOOD_INTERRUPTED_WRITE"

// TestHelperInterruptedWrite is not a test of its own: crash runs it in a child process. It
// starts a write on the library its environment names, too large for SQLite to keep in memory,
// so the write spills to the file before any commit, says so, and waits to be killed.
func TestHelperInterruptedWrite(t *testing.T) {
	path := os.Getenv(crashEnv)
	if path == "" {
		t.Skip("crash runs this in a child process")
	}
	d, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	d.SetMaxOpenConns(1)
	if _, err := d.Exec(`PRAGMA cache_size = 10`); err != nil {
		t.Fatal(err)
	}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(`UPDATE course SET title = 'Changed by a write that never finished'`); err != nil {
		t.Fatal(err)
	}
	for i := range 400 {
		if _, err := tx.Exec(`INSERT INTO setting VALUES (?, ?)`, fmt.Sprintf("unfinished.%03d", i), strings.Repeat("x", 4000)); err != nil {
			t.Fatal(err)
		}
	}
	fmt.Println("spilled")
	time.Sleep(time.Minute) // killed long before this ends
}

// crash interrupts a write on the library at path as a crash or Ctrl-C would, leaving its
// hot journal.
func crash(t *testing.T, path string) {
	t.Helper()
	cmd := osexec.Command(os.Args[0], "-test.run=^TestHelperInterruptedWrite$")
	cmd.Env = append(os.Environ(), crashEnv+"="+path)
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	spilled := make(chan bool, 1)
	go func() {
		for sc := bufio.NewScanner(out); sc.Scan(); {
			if sc.Text() == "spilled" {
				spilled <- true
				return
			}
		}
		spilled <- false
	}()
	select {
	case ok := <-spilled:
		if !ok {
			t.Fatal("the writer ended before its write spilled to the file")
		}
	case <-time.After(time.Minute):
		t.Fatal("the writer did not spill in time")
	}
	cmd.Process.Kill()
	cmd.Wait()
	if info, err := os.Stat(path + "-journal"); err != nil || info.Size() == 0 {
		t.Fatalf("no hot journal after the crash: %v", err)
	}
}

func TestCheckRecoversAnInterruptedWrite(t *testing.T) {
	path := newLibrary(t, smallLibrary...)
	_, ok, _ := runCmd(t, "check", path)
	crash(t, path)

	code, out, errOut := runCmd(t, "check", path)
	if want := db.RecoveredMessage(path) + "\n" + ok; code != 0 || out != want {
		t.Fatalf("check after a crash: exit %d, stderr %q, printed\n%s\nwant\n%s", code, errOut, out, want)
	}
	if _, err := os.Stat(path + "-journal"); err == nil {
		t.Error("the journal is still there")
	}
	d, _, err := db.Inspect(path)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	var title string
	var unfinished int
	d.QueryRow(`SELECT (SELECT title FROM course), (SELECT count(*) FROM setting WHERE key LIKE 'unfinished.%')`).Scan(&title, &unfinished)
	if title != "Learn Testing" || unfinished != 0 {
		t.Errorf("after recovering: course title %q and %d unfinished settings; want the state before the write", title, unfinished)
	}
	if code, again, _ := runCmd(t, "check", path); code != 0 || again != ok {
		t.Errorf("a second check: %d %q, want %q", code, again, ok)
	}
}
