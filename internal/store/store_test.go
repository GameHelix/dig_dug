package store

// Every lesson here is invented: lessons of a fictional space startup's course, one of each
// type, which between them fill every table that holds a lesson's parts.

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jobloom/gopherwood/db"
)

const (
	created = "2026-11-01T09:00:00Z"
	edited  = "2026-11-01T10:00:00Z"
)

// newLibrary makes an empty library with one course of two chapters, ch-countdown and ch-orbit.
func newLibrary(t *testing.T) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "apogee.sqlite")
	d, err := db.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	for _, s := range []string{
		`INSERT INTO course VALUES ('c-launches', 'learn-launches', 'Learn Launches', 'Course', 'Launch code.', 'An invented course.', 0)`,
		`INSERT INTO chapter VALUES ('ch-countdown', 'c-launches', 0, '1-countdown', 'Countdown', '')`,
		`INSERT INTO chapter VALUES ('ch-orbit', 'c-launches', 1, '2-orbit', 'Orbit', '')`,
	} {
		if _, err := d.Exec(s); err != nil {
			t.Fatal(err)
		}
	}
	return d, path
}

// lesson returns a lesson row in chapter ch-countdown.
func lesson(uuid, slug, typ string, position int64, readme string) Lesson {
	l := Lesson{
		UUID: uuid, ChapterUUID: "ch-countdown", Position: position, Slug: slug, Title: "Lesson " + slug, Type: typ,
		Required: true, Difficulty: 10, Readme: readme, CreatedAt: created, LastMod: created, SyncedAt: created,
	}
	if typ == "type_code" || typ == "type_code_tests" {
		l.CodeLastMod = sql.NullString{String: created, Valid: true}
	}
	return l
}

// record returns a record whose rows all belong to uuid: each row lists its values after the
// lesson's uuid.
func record(l Lesson, rows ...Row) Record {
	for i := range rows {
		rows[i].Vals = append([]any{l.UUID}, rows[i].Vals...)
	}
	return Record{Lesson: l, Rows: rows}
}

func row(table string, vals ...any) Row { return Row{Table: table, Vals: vals} }

const (
	starterMain = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Window opens at T-minus ? seconds\")\n}\n"
	solvedMain  = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Printf(\"Window opens at T-minus %d seconds\\n\", windowOpens)\n}\n"
	clock       = "package main\n\nconst windowOpens = 90\n"
)

func codeLesson() Record {
	return record(lesson("l-window", "launch-window", "type_code", 0, "# Launch Window\n\nPrint when the launch window opens.\n"),
		row("lesson_topic", "constants"),
		row("lesson_topic", "printing"),
		row("code_lesson", "type_code", "go", "Window opens at T-minus 90 seconds\n"),
		row("starter_file", "clock.go", int64(0), clock, int64(1), int64(0)),
		row("starter_file", "main.go", int64(1), starterMain, int64(0), int64(0)),
		row("solution_file", "main.go", solvedMain),
	)
}

func testsLesson() Record {
	return record(lesson("l-fuel", "fuel-budget", "type_code_tests", 1, "# Fuel Budget\n\nReturn the fuel left after a burn.\n"),
		row("lesson_topic", "functions"),
		row("code_lesson", "type_code_tests", "go", nil),
		row("starter_file", "fuel.go", int64(0), "package main\n\nfunc Remaining(tank, burn int) int {\n\treturn 0\n}\n", int64(0), int64(0)),
		row("starter_file", "fuel_test.go", int64(1), "package main\n\nimport \"testing\"\n\nfunc TestRemaining(t *testing.T) {\n\tif got := Remaining(100, 30); got != 70 {\n\t\tt.Errorf(\"Remaining(100, 30) = %d, want 70\", got)\n\t}\n}\n", int64(0), int64(1)),
		row("solution_file", "fuel.go", "package main\n\nfunc Remaining(tank, burn int) int {\n\treturn max(tank-burn, 0)\n}\n"),
	)
}

func quizLesson() Record {
	return record(lesson("l-quiz", "mission-quiz", "type_choice", 2, "# Mission Quiz\n\nCheck what you know about the countdown.\n"),
		row("quiz_lesson", "type_choice", int64(0)),
		row("quiz_question", int64(0), "Which constant holds the launch window?"),
		row("quiz_answer", int64(0), int64(0), "launchAt", int64(0)),
		row("quiz_answer", int64(0), int64(1), "windowOpens", int64(1)),
		row("quiz_question", int64(1), "Does a scrub reset the countdown?"),
		row("quiz_answer", int64(1), int64(0), "Yes", int64(1)),
		row("quiz_answer", int64(1), int64(1), "No", int64(0)),
	)
}

func cliLesson() Record {
	return record(lesson("l-station", "ground-station", "type_cli", 3, "# Ground Station\n\nRun the telemetry server and talk to it.\n"),
		row("cli_lesson", "type_cli", "http://localhost:8080", int64(0), int64(0), int64(0)),
		row("cli_lesson_os", "darwin"),
		row("cli_lesson_os", "linux"),
		row("cli_step", int64(0), "command", "Build the telemetry server.", int64(0), nil),
		row("cli_command", int64(0), "command", "./telemetry --version", nil),
		row("cli_command_variable", int64(0), int64(0), "version", `v(\d+\.\d+)`),
		row("cli_command_test", int64(0), int64(0), "exit_code", int64(0), nil, nil, nil),
		row("cli_command_test", int64(0), int64(1), "stdout_contains_all", nil, nil, nil, nil),
		row("cli_command_test_text", int64(0), int64(1), "stdout_contains_all", int64(0), "telemetry"),
		row("cli_command_test", int64(0), int64(2), "stdout_jq", nil, nil, ".status", "json"),
		row("cli_command_test_jq_result", int64(0), int64(2), "stdout_jq", int64(0), "==", "string", nil, nil, "ok"),
		row("cli_step", int64(1), "http", "Send the server a reading.", int64(1), int64(500)),
		row("cli_http_request", int64(1), "http", "POST", "${baseURL}/readings", int64(1), "pilot", "countdown", "json", `{"altitude": 1200}`),
		row("cli_http_header", int64(1), int64(0), "X-Probe", "apogee-1"),
		row("cli_http_body_variable", int64(1), int64(0), "readingID", ".id", nil),
		row("cli_http_header_variable", int64(1), int64(0), "location", "Location", nil),
		row("cli_http_test", int64(1), int64(0), "status_code", int64(201), nil, nil, nil, nil, nil, nil, nil, nil, nil),
		row("cli_http_test", int64(1), int64(1), "json_value", nil, nil, nil, nil, ".altitude", "eq", "int", nil, int64(1200), nil),
		row("cli_http_test", int64(1), int64(2), "headers_contain", nil, nil, "Content-Type", "application/json", nil, nil, nil, nil, nil, nil),
		row("cli_step", int64(2), "http", "Log in at the console.", int64(0), nil),
		row("cli_http_request", int64(2), "http", "POST", "${baseURL}/login", int64(0), nil, nil, "form", nil),
		row("cli_http_form_field", int64(2), "form", int64(0), "callsign", "apogee"),
		row("cli_http_test", int64(2), int64(0), "body_contains", nil, "welcome", nil, nil, nil, nil, nil, nil, nil, nil),
	)
}

func githubLesson() Record {
	return record(lesson("l-repo", "flight-log-repo", "type_github_checks", 4, "# Flight Log Repository\n\nPublish the flight log.\n"),
		row("github_lesson", "type_github_checks", int64(0), int64(0)),
		row("github_step", int64(0), "repo_exists", nil, nil, nil, nil, nil, nil, nil, nil),
		row("github_step", int64(1), "branch_exists", "telemetry", nil, nil, nil, nil, nil, nil, nil),
		row("github_step", int64(2), "file_contains", nil, "README.md", nil, nil, nil, nil, nil, nil),
		row("github_file_text", int64(2), "file_contains", int64(0), "# Flight log"),
		row("github_step", int64(3), "pr_exists", nil, nil, "apogee-space", "flight-log", "main", "telemetry", nil, nil),
		row("github_step", int64(4), "workflow_status", nil, nil, nil, nil, nil, nil, "ci", "success"),
		row("github_step", int64(5), "workflow_logs_contains", nil, nil, nil, nil, nil, nil, "ci", nil),
		row("github_log_text", int64(5), "workflow_logs_contains", "test", int64(0), "PASS"),
	)
}

func interviewLesson() Record {
	return record(lesson("l-review", "mission-review", "type_interview_chat", 5, "# Mission Review\n\nWalk the flight director through a scrub.\n"),
		row("interview_lesson", "type_interview_chat", "Explain what the countdown does when a launch is scrubbed.", "Says the timer stops and starts again from the top."),
	)
}

func everyType() []Record {
	return []Record{codeLesson(), testsLesson(), quizLesson(), cliLesson(), githubLesson(), interviewLesson()}
}

func put(t *testing.T, d *sql.DB, recs ...Record) {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	for _, r := range recs {
		if err := Put(tx, r); err != nil {
			t.Fatalf("%s: %v", r.Lesson.Slug, err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

// mustCheck fails unless the library passes the checks the app makes and its search index
// agrees with the lesson table.
func mustCheck(t *testing.T, d *sql.DB) {
	t.Helper()
	if p, err := db.Validate(context.Background(), d); err != nil || len(p) > 0 {
		t.Fatal(p, err)
	}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT INTO lesson_search(lesson_search, rank) VALUES ('integrity-check', 1)`); err != nil {
		t.Fatalf("search index: %v", err)
	}
}

func count(t *testing.T, d *sql.DB, query string, args ...any) int {
	t.Helper()
	var n int
	if err := d.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return n
}

func TestTableColumnsMatchTheSchema(t *testing.T) {
	d, _ := newLibrary(t)
	keys := make([]string, 0, len(tableCols))
	for k := range tableCols {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if parts := slices.Sorted(slices.Values(partTables)); !slices.Equal(keys, parts) {
		t.Errorf("partTables %v and tableCols %v differ", parts, keys)
	}
	for _, table := range partTables {
		rows, err := d.Query(`SELECT name FROM pragma_table_info(?) ORDER BY cid`, table)
		if err != nil {
			t.Fatal(err)
		}
		var cols []string
		for rows.Next() {
			var c string
			if err := rows.Scan(&c); err != nil {
				t.Fatal(err)
			}
			cols = append(cols, c)
		}
		rows.Close()
		if !slices.Equal(cols, tableCols[table]) {
			t.Errorf("%s: the schema has %v, tableCols %v", table, cols, tableCols[table])
		}
	}
	// Every table with a lesson_uuid column holds a lesson's parts, except the learner's own.
	n := count(t, d, `SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND sql LIKE '%lesson_uuid%' AND name NOT IN ('progress', 'attempt', 'note', 'code_file')`)
	if n != len(partTables) {
		t.Errorf("the schema has %d tables of a lesson's parts, partTables %d", n, len(partTables))
	}
}

func TestPutEveryType(t *testing.T) {
	d, path := newLibrary(t)
	recs := everyType()
	put(t, d, recs...)
	mustCheck(t, d)
	for _, table := range partTables {
		if count(t, d, `SELECT count(*) FROM `+table) == 0 {
			t.Errorf("no %s rows", table)
		}
	}
	for _, r := range recs {
		got, ok, err := Get(d, r.Lesson.UUID)
		if err != nil || !ok || got != r.Lesson {
			t.Errorf("Get(%s) = %+v, %v, %v; want %+v", r.Lesson.UUID, got, ok, err, r.Lesson)
		}
		parts, err := ReadParts(d, r.Lesson.UUID)
		if err != nil {
			t.Fatal(err)
		}
		if diff := PartsDiff(parts, r.Rows); len(diff) > 0 {
			t.Errorf("%s: read back different %v", r.Lesson.Slug, diff)
		}
	}
	if count(t, d, `SELECT count(*) FROM lesson_search WHERE lesson_search MATCH 'telemetry'`) != 1 {
		t.Error("search does not find the ground station lesson")
	}

	// Writing the same lessons again changes nothing, down to the file's bytes.
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	put(t, d, everyType()...)
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("writing the same lessons again changed the file")
	}
}

func TestPutRewritesInPlace(t *testing.T) {
	d, _ := newLibrary(t)
	put(t, d, quizLesson())
	id := count(t, d, `SELECT id FROM lesson WHERE uuid = 'l-quiz'`)
	if _, err := d.Exec(`INSERT INTO progress VALUES ('l-quiz', '2026-11-01T11:00:00Z', NULL)`); err != nil {
		t.Fatal(err)
	}

	old := quizLesson()
	changed := quizLesson()
	changed.Lesson.Readme = "# Mission Quiz\n\nA zenith of a quiz.\n"
	changed.Lesson.LastMod, changed.Lesson.SyncedAt = edited, edited
	changed.Rows[1].Vals[2] = "Which constant says when the window opens?"
	if diff := LessonDiff(old.Lesson, changed.Lesson); !slices.Equal(diff, []string{"readme", "last_mod"}) {
		t.Errorf("LessonDiff = %v, want [readme last_mod]", diff)
	}
	if diff := PartsDiff(old.Rows, changed.Rows); !slices.Equal(diff, []string{"quiz_question"}) {
		t.Errorf("PartsDiff = %v, want [quiz_question]", diff)
	}
	put(t, d, changed)

	if got := count(t, d, `SELECT id FROM lesson WHERE uuid = 'l-quiz'`); got != id {
		t.Errorf("the lesson's id %d became %d", id, got)
	}
	if count(t, d, `SELECT count(*) FROM lesson_search WHERE lesson_search MATCH 'zenith'`) != 1 ||
		count(t, d, `SELECT count(*) FROM lesson_search WHERE lesson_search MATCH 'countdown'`) != 0 {
		t.Error("the search index does not follow the new readme")
	}
	if count(t, d, `SELECT count(*) FROM quiz_question WHERE question = 'Which constant says when the window opens?'`) != 1 ||
		count(t, d, `SELECT count(*) FROM quiz_answer WHERE lesson_uuid = 'l-quiz'`) != 4 {
		t.Error("the quiz's rows were not rewritten")
	}
	if count(t, d, `SELECT count(*) FROM progress WHERE lesson_uuid = 'l-quiz'`) != 1 {
		t.Error("the learner's progress on the lesson is gone")
	}
	got, _, _ := Get(d, "l-quiz")
	if got != changed.Lesson {
		t.Errorf("Get = %+v, want %+v", got, changed.Lesson)
	}
	mustCheck(t, d)

	// A lesson moved to another chapter keeps its id too.
	moved := changed
	moved.Lesson.ChapterUUID, moved.Lesson.Position = "ch-orbit", 0
	if diff := LessonDiff(changed.Lesson, moved.Lesson); !slices.Equal(diff, []string{"chapter", "position"}) {
		t.Errorf("LessonDiff = %v, want [chapter position]", diff)
	}
	put(t, d, moved)
	if count(t, d, `SELECT count(*) FROM lesson WHERE uuid = 'l-quiz' AND chapter_uuid = 'ch-orbit' AND id = ?`, id) != 1 {
		t.Error("the lesson did not move in place")
	}
	mustCheck(t, d)
}

func TestPutChangesType(t *testing.T) {
	d, _ := newLibrary(t)
	put(t, d, codeLesson())

	// The same lesson, now a quiz: its code rows go and the quiz's take their place.
	quiz := quizLesson()
	quiz.Lesson.UUID, quiz.Lesson.Slug, quiz.Lesson.Position = "l-window", "launch-window", 0
	for i := range quiz.Rows {
		quiz.Rows[i].Vals[0] = "l-window"
	}
	put(t, d, quiz)
	for table, want := range map[string]int{"code_lesson": 0, "starter_file": 0, "solution_file": 0, "lesson_topic": 0, "quiz_lesson": 1, "quiz_question": 2, "quiz_answer": 4} {
		if got := count(t, d, `SELECT count(*) FROM `+table+` WHERE lesson_uuid = 'l-window'`); got != want {
			t.Errorf("%s: %d rows, want %d", table, got, want)
		}
	}
	mustCheck(t, d)
}

func TestPutRefuses(t *testing.T) {
	d, _ := newLibrary(t)
	put(t, d, codeLesson())
	taken := testsLesson()
	taken.Lesson.Slug = "launch-window"
	unknown := quizLesson()
	unknown.Rows = append(unknown.Rows, row("rocket", "l-quiz"))
	for _, tc := range []struct {
		name string
		rec  Record
		want string
	}{
		{"a slug another lesson of the chapter has", taken, `lesson l-window already has the slug "launch-window" in this chapter`},
		{"a row of a table that holds no lesson parts", unknown, "rocket is not a table of a lesson's parts"},
	} {
		tx, err := d.Begin()
		if err != nil {
			t.Fatal(err)
		}
		if err := Put(tx, tc.rec); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: %v, want %q", tc.name, err, tc.want)
		}
		tx.Rollback()
	}
	if count(t, d, `SELECT count(*) FROM lesson`) != 1 {
		t.Error("a refused lesson was written")
	}
}

func TestUTC(t *testing.T) {
	baku := time.FixedZone("UTC+4", 4*60*60)
	if got := UTC(time.Date(2026, 11, 1, 14, 30, 15, 999_000_000, baku)); got != "2026-11-01T10:30:15Z" {
		t.Errorf("UTC = %s", got)
	}
}
