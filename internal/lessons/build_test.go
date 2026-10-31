package lessons

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/jobloom/gopherwood/internal/media"
)

// The fixtures are real lessons, one or more of every type, copied from boot.dev's Go courses
// without their pictures. Between them they use every table a lesson has.
func fixtures(t *testing.T) map[string]map[string]any {
	t.Helper()
	files, err := filepath.Glob("testdata/lessons/*.json")
	if err != nil || len(files) == 0 {
		t.Fatalf("no fixtures: %v", err)
	}
	out := map[string]map[string]any{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		obj, err := DecodeObject(b)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		out[strings.TrimSuffix(filepath.Base(f), ".json")] = obj
	}
	return out
}

func fixture(t *testing.T, uuid string) map[string]any {
	t.Helper()
	b, err := os.ReadFile("testdata/lessons/" + uuid + ".json")
	if err != nil {
		t.Fatal(err)
	}
	obj, err := DecodeObject(b)
	if err != nil {
		t.Fatal(err)
	}
	return obj
}

// rowsOf returns a record's rows of one table as maps by column name.
func rowsOf(rec Record, table string) []map[string]any {
	var out []map[string]any
	for _, r := range rec.Rows {
		if r.Table != table {
			continue
		}
		m := map[string]any{}
		for i, c := range TableCols[table] {
			m[c] = r.Vals[i]
		}
		out = append(out, m)
	}
	return out
}

func anyRow(rows []map[string]any, match map[string]any) bool {
	for _, r := range rows {
		ok := true
		for k, v := range match {
			if r[k] != v {
				ok = false
			}
		}
		if ok {
			return true
		}
	}
	return false
}

func TestBuildEveryFixture(t *testing.T) {
	types := map[string]bool{}
	tables := map[string]bool{}
	for uuid, obj := range fixtures(t) {
		rec, err := Build(obj)
		if err != nil {
			t.Errorf("%s: %v", uuid, err)
			continue
		}
		l := rec.Lesson
		types[l.Type] = true
		for _, r := range rec.Rows {
			tables[r.Table] = true
			if len(r.Vals) != len(TableCols[r.Table]) || r.Vals[0] != uuid {
				t.Errorf("%s: a %s row has %d values for %d columns, or another lesson's uuid", uuid, r.Table, len(r.Vals), len(TableCols[r.Table]))
			}
		}
		switch {
		case l.UUID != uuid:
			t.Errorf("%s: uuid %s", uuid, l.UUID)
		case l.Difficulty <= 0 || l.Slug == "" || l.Title == "" || l.Readme == "":
			t.Errorf("%s: difficulty %d, slug %q, title %q, readme %d bytes", uuid, l.Difficulty, l.Slug, l.Title, len(l.Readme))
		case !strings.HasSuffix(l.CreatedAt, "Z") || !strings.HasSuffix(l.LastMod, "Z") || (l.CodeLastMod.Valid && !strings.HasSuffix(l.CodeLastMod.String, "Z")):
			t.Errorf("%s: times not in UTC: %s %s %v", uuid, l.CreatedAt, l.LastMod, l.CodeLastMod)
		case rec.Media.Total() != 0:
			t.Errorf("%s: the fixture should have no media, found %+v", uuid, rec.Media)
		}
		if n := len(rowsOf(rec, map[string]string{"type_code": "code_lesson", "type_code_tests": "code_lesson", "type_choice": "quiz_lesson",
			"type_cli": "cli_lesson", "type_github_checks": "github_lesson", "type_interview_chat": "interview_lesson"}[l.Type])); n != 1 {
			t.Errorf("%s: %d per-type rows", uuid, n)
		}
	}
	if len(types) != 6 {
		t.Errorf("the fixtures cover types %v, want all six", types)
	}
	for _, table := range PartTables {
		if !tables[table] {
			t.Errorf("no fixture has a %s row", table)
		}
	}
}

func TestBuildMapping(t *testing.T) {
	for _, tc := range []struct {
		name  string
		uuid  string
		check func(t *testing.T, rec Record)
	}{
		{"lastMod and codeLastMod move to UTC", "22b72d79-74ef-46c1-88f4-e0440df0d48e", func(t *testing.T, rec Record) {
			obj := fixture(t, "22b72d79-74ef-46c1-88f4-e0440df0d48e")
			if lm := str(obj["lastMod"]); strings.HasSuffix(lm, "Z") || rec.Lesson.LastMod == lm {
				t.Errorf("lastMod %s became %s", lm, rec.Lesson.LastMod)
			}
		}},
		{"type_code keeps its expected output", "22b72d79-74ef-46c1-88f4-e0440df0d48e", func(t *testing.T, rec Record) {
			code := rowsOf(rec, "code_lesson")[0]
			if code["lesson_type"] != "type_code" || code["expected_output"] == nil || code["prog_lang"] != "go" {
				t.Errorf("code_lesson = %v", code)
			}
		}},
		{"type_code_tests has no expected output, and hidden and read-only files", "79af6279-daae-43e3-998a-5bac514a76db", func(t *testing.T, rec Record) {
			if code := rowsOf(rec, "code_lesson")[0]; code["expected_output"] != nil {
				t.Errorf("code_lesson = %v", code)
			}
			files := rowsOf(rec, "starter_file")
			if !anyRow(files, map[string]any{"is_hidden": int64(1)}) || !anyRow(files, map[string]any{"is_readonly": int64(1)}) || !anyRow(files, map[string]any{"is_hidden": int64(0), "is_readonly": int64(0)}) {
				t.Errorf("starter files = %v", files)
			}
		}},
		{"a quiz has one right answer per question, and no codeLastMod is NULL", "5a477eea-341f-4de8-b9f7-8e2dcde75ef6", func(t *testing.T, rec Record) {
			right := map[any]int{}
			for _, a := range rowsOf(rec, "quiz_answer") {
				if a["is_correct"] == int64(1) {
					right[a["question_position"]]++
				}
			}
			for _, q := range rowsOf(rec, "quiz_question") {
				if right[q["position"]] != 1 {
					t.Errorf("question %v has %d right answers", q["position"], right[q["position"]])
				}
			}
			if rec.Lesson.CodeLastMod.Valid {
				t.Errorf("code_last_mod = %v, want NULL", rec.Lesson.CodeLastMod)
			}
		}},
		{"a pull request into your own repository has no owner or repo", "c140afde-0a53-4086-873f-0785b6fa4618", func(t *testing.T, rec Record) {
			if !anyRow(rowsOf(rec, "github_step"), map[string]any{"kind": "pr_exists", "pr_base_owner": nil, "pr_base_repo": nil, "pr_base_branch": "main", "pr_compare_branch": "addtests"}) {
				t.Errorf("github_step = %v", rowsOf(rec, "github_step"))
			}
		}},
		{"showcaseRepo null is 0", "55d273f2-5d8f-4acc-9493-bf8be8aea700", func(t *testing.T, rec Record) {
			if g := rowsOf(rec, "github_lesson")[0]; g["showcase_repo"] != int64(0) {
				t.Errorf("github_lesson = %v", g)
			}
		}},
		{"redirects: null follows, false does not; jq input '' is json; a header capture with a regex", "efe611fa-4e6d-4145-9bf4-0a8f60bd15fb", func(t *testing.T, rec Record) {
			reqs := rowsOf(rec, "cli_http_request")
			if !anyRow(reqs, map[string]any{"follow_redirects": int64(0)}) || !anyRow(reqs, map[string]any{"follow_redirects": int64(1)}) {
				t.Errorf("follow_redirects never both: %v", reqs)
			}
			if !anyRow(rowsOf(rec, "cli_command_test"), map[string]any{"kind": "stdout_jq", "jq_input": "json"}) {
				t.Errorf("cli_command_test = %v", rowsOf(rec, "cli_command_test"))
			}
			if !anyRow(reqs, map[string]any{"body_kind": "form"}) || len(rowsOf(rec, "cli_http_form_field")) == 0 {
				t.Error("the form body is missing")
			}
		}},
		{"a JSON body is kept whole", "12c3079a-d98a-4170-b7cc-82029d53e5c1", func(t *testing.T, rec Record) {
			for _, r := range rowsOf(rec, "cli_http_request") {
				if r["body_kind"] == "json" {
					var v any
					if err := json.Unmarshal([]byte(r["body_json"].(string)), &v); err != nil {
						t.Errorf("body_json %q: %v", r["body_json"], err)
					}
					return
				}
			}
			t.Error("no JSON body")
		}},
		{"a whole-header capture has no regex; a body capture by regex has no path", "8119c1a8-8a1e-49ca-a9a0-031d0b05ff71", func(t *testing.T, rec Record) {
			if !anyRow(rowsOf(rec, "cli_http_header_variable"), map[string]any{"regex": nil}) {
				t.Errorf("cli_http_header_variable = %v", rowsOf(rec, "cli_http_header_variable"))
			}
			if !anyRow(rowsOf(rec, "cli_http_body_variable"), map[string]any{"json_path": nil}) {
				t.Errorf("cli_http_body_variable = %v", rowsOf(rec, "cli_http_body_variable"))
			}
		}},
		{"a command's pause moves to its step", "db0c9eab-4f43-4e65-8b54-e41c61c2eafb", func(t *testing.T, rec Record) {
			for _, s := range rowsOf(rec, "cli_step") {
				if s["kind"] == "command" && s["sleep_after_ms"] != nil {
					return
				}
			}
			t.Errorf("cli_step = %v", rowsOf(rec, "cli_step"))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec, err := Build(fixture(t, tc.uuid))
			if err != nil {
				t.Fatal(err)
			}
			tc.check(t, rec)
		})
	}
}

// Acceptance criteria that are empty or blank are NULL: the lesson gives none. Real criteria
// are kept exactly.
func TestBuildAcceptanceCriteria(t *testing.T) {
	const interview = "190a30a7-1a43-46d5-bb0a-249344b8e89c"
	for _, tc := range []struct {
		value any
		want  any
	}{
		{"", nil},
		{" \t\n ", nil},
		{nil, nil},
		{"Names the fields to log.", "Names the fields to log."},
		{"  Keeps its spaces.\n", "  Keeps its spaces.\n"},
	} {
		obj := fixture(t, interview)
		set(obj, tc.value, "lessonDataInterviewChat", "acceptanceCriteria")
		rec, err := Build(obj)
		if err != nil {
			t.Fatal(err)
		}
		if got := rowsOf(rec, "interview_lesson")[0]["acceptance_criteria"]; got != tc.want {
			t.Errorf("acceptanceCriteria %q: stored %#v, want %#v", tc.value, got, tc.want)
		}
	}
}

// A suggested address is kept; the source's 'override' means the lesson asks for the address of
// your own server, and suggests none.
func TestBuildBaseURL(t *testing.T) {
	const cli = "bbbe7d5d-5eed-4ceb-884d-07f77ff735b7"
	for _, tc := range []struct {
		value    any
		wantBase any
		wantAsks int64
	}{
		{"http://localhost:8080", "http://localhost:8080", 0},
		{"override", nil, 1},
		{"", nil, 0},
		{nil, nil, 0},
	} {
		obj := fixture(t, cli)
		set(obj, tc.value, "lessonDataCLI", "cliData", "baseURLDefault")
		rec, err := Build(obj)
		if err != nil {
			t.Fatal(err)
		}
		row := rowsOf(rec, "cli_lesson")[0]
		if row["base_url_default"] != tc.wantBase || row["asks_for_base_url"] != tc.wantAsks {
			t.Errorf("baseURLDefault %v: cli_lesson = %v", tc.value, row)
		}
	}
}

// set changes a fixture: keys lead into nested objects and arrays (by index, as strings).
func set(obj map[string]any, value any, keys ...string) {
	var v any = obj
	for i, k := range keys {
		last := i == len(keys)-1
		switch c := v.(type) {
		case map[string]any:
			if last {
				c[k] = value
				return
			}
			v = c[k]
		case []any:
			n := 0
			for _, d := range k {
				n = n*10 + int(d-'0')
			}
			if last {
				c[n] = value
				return
			}
			v = c[n]
		}
	}
}

func TestBuildRefuses(t *testing.T) {
	const quiz, cli, gh = "5a477eea-341f-4de8-b9f7-8e2dcde75ef6", "bbbe7d5d-5eed-4ceb-884d-07f77ff735b7", "04a447c0-2c25-4011-8138-d448a23b5fd6"
	for _, tc := range []struct {
		name   string
		uuid   string
		change func(obj map[string]any)
		want   string
	}{
		{"an unknown lesson type", quiz, func(o map[string]any) { o["type"] = "type_video" }, "not one the database knows"},
		{"a missing payload", quiz, func(o map[string]any) { delete(o, "lessonDataMultipleChoice") }, "without lessonDataMultipleChoice"},
		{"no difficulty", quiz, func(o map[string]any) { o["absoluteDifficulty"] = json.Number("0") }, "absoluteDifficulty"},
		{"a bad lastMod", quiz, func(o map[string]any) { o["lastMod"] = "yesterday" }, "lastMod"},
		{"a question without its right answer", quiz, func(o map[string]any) {
			set(o, "none of these", "lessonDataMultipleChoice", "questions", "0", "answer")
		}, "0 right answers"},
		{"an answer listed twice", quiz, func(o map[string]any) {
			q := o["lessonDataMultipleChoice"].(map[string]any)["questions"].([]any)[0].(map[string]any)
			answers := q["answers"].([]any)
			q["answers"] = append(answers, answers[0])
		}, "twice"},
		{"a step that is both a command and a request", cli, func(o map[string]any) {
			set(o, map[string]any{"request": map[string]any{"method": "GET"}}, "lessonDataCLI", "cliData", "steps", "0", "httpRequest")
		}, "exactly one of"},
		{"a test that sets two fields", cli, func(o map[string]any) {
			set(o, json.Number("0"), "lessonDataCLI", "cliData", "steps", "0", "cliCommand", "tests", "0", "stdoutLinesGT")
			set(o, json.Number("1"), "lessonDataCLI", "cliData", "steps", "0", "cliCommand", "tests", "0", "exitCode")
		}, "sets both"},
		{"an unknown operating system", cli, func(o map[string]any) {
			set(o, []any{"plan9"}, "lessonDataCLI", "cliData", "allowedOperatingSystems")
		}, "operating system"},
		{"an unknown GitHub check", gh, func(o map[string]any) {
			set(o, "star_repo", "lessonDataGitHubChecks", "gitHubChecks", "steps", "0", "stepType")
		}, "unknown check"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			obj := fixture(t, tc.uuid)
			tc.change(obj)
			if _, err := Build(obj); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("Build: err = %v, want it to say %q", err, tc.want)
			}
		})
	}
}

// Prose loses its media; the right answer stays right.
func TestBuildStripsMediaFromProse(t *testing.T) {
	obj := fixture(t, "5a477eea-341f-4de8-b9f7-8e2dcde75ef6")
	data := obj["lessonDataMultipleChoice"].(map[string]any)
	data["readme"] = "Intro.\n\n![diagram](https://x/d.png)\n\n" + data["readme"].(string)
	q := data["questions"].([]any)[0].(map[string]any)
	q["question"] = "Watch [the talk](https://www.youtube.com/watch?v=x) first. " + q["question"].(string)
	right := q["answer"].(string)
	withVideo := right + " ![clip](https://x/clip.mp4)"
	q["answer"] = withVideo
	answers := q["answers"].([]any)
	for i, a := range answers {
		if a == right {
			answers[i] = withVideo
		}
	}
	rec, err := Build(obj)
	if err != nil {
		t.Fatal(err)
	}
	if rec.Media != (media.Stats{Images: 1, Videos: 1, Links: 1}) {
		t.Errorf("removed %+v, want a picture, a video and a link", rec.Media)
	}
	if strings.Contains(rec.Lesson.Readme, "![") || !strings.HasPrefix(rec.Lesson.Readme, "Intro.\n\n") {
		t.Errorf("readme = %q", rec.Lesson.Readme[:40])
	}
	question := rowsOf(rec, "quiz_question")[0]["question"].(string)
	if !strings.HasPrefix(question, "Watch the talk first. ") {
		t.Errorf("question = %q", question)
	}
	if !anyRow(rowsOf(rec, "quiz_answer"), map[string]any{"question_position": int64(0), "answer": right, "is_correct": int64(1)}) {
		t.Errorf("the right answer lost its mark: %v", rowsOf(rec, "quiz_answer"))
	}
}

// A widget's settings go with the widget; the readme's code blocks stay.
func TestBuildStripsWidgets(t *testing.T) {
	obj := fixture(t, "22b72d79-74ef-46c1-88f4-e0440df0d48e")
	data := obj["lessonDataCodeOutput"].(map[string]any)
	readme := data["readme"].(string)
	data["readme"] = "Slices, shown by the widget below.\n\n```widget sequence-slicing\n{\n  \"dialect\": \"go\"\n}\n```\n\n" + readme
	rec, err := Build(obj)
	if err != nil {
		t.Fatal(err)
	}
	if want := "Slices, shown by the widget below.\n\n" + readme; rec.Lesson.Readme != want {
		t.Errorf("readme = %q...", rec.Lesson.Readme[:60])
	}
	if rec.Media != (media.Stats{Widgets: 1}) {
		t.Errorf("removed %+v, want one widget", rec.Media)
	}
}

func TestTableColumnsMatchTheSchema(t *testing.T) {
	d := newDB(t)
	keys := sortedKeys(TableCols)
	parts := slices.Clone(PartTables)
	sort.Strings(parts)
	if !slices.Equal(keys, parts) {
		t.Errorf("PartTables %v and TableCols %v differ", parts, keys)
	}
	for _, table := range PartTables {
		rows, err := d.Query(`SELECT name FROM pragma_table_info(?) ORDER BY cid`, table)
		if err != nil {
			t.Fatal(err)
		}
		var cols []string
		for rows.Next() {
			var c string
			rows.Scan(&c)
			cols = append(cols, c)
		}
		rows.Close()
		if !slices.Equal(cols, TableCols[table]) {
			t.Errorf("%s: schema has %v, TableCols %v", table, cols, TableCols[table])
		}
	}
	var n int
	if err := d.QueryRow(`SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND sql LIKE '%lesson_uuid%' AND name NOT IN ('progress', 'attempt', 'note', 'code_file')`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != len(PartTables) {
		t.Errorf("the schema has %d lesson part tables, PartTables %d", n, len(PartTables))
	}
	_ = sql.ErrNoRows
}
