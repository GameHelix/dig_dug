package main

// Every course, chapter and lesson here is invented: lessons for a fictional space startup,
// Apogee, from internal/authoring/testdata/packages.

import (
	"bytes"
	"context"
	"database/sql"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jobloom/gopherwood/db"
	"github.com/jobloom/gopherwood/internal/authoring"
)

func example(name string) string {
	return filepath.Join("..", "..", "internal", "authoring", "testdata", "packages", name)
}

func author(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := run(context.Background(), args, &out, &errOut)
	return code, out.String(), errOut.String()
}

func mustAuthor(t *testing.T, args ...string) string {
	t.Helper()
	code, out, errOut := author(t, args...)
	if code != 0 {
		t.Fatalf("author %v: exit %d: %s", args, code, errOut)
	}
	return out
}

// library makes a library with the course learn-launches and its chapter 1-countdown.
func library(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "apogee.sqlite")
	d, err := db.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	d.Close()
	mustAuthor(t, "course", path, "--slug", "learn-launches", "--title", "Learn Launches", "--kind", "Course",
		"--short", "Write the code that flies Apogee's rockets.", "--description", "A course of invented lessons.")
	mustAuthor(t, "chapter", path, "--course", "learn-launches", "--slug", "1-countdown", "--title", "Countdown",
		"--description", "The minutes before liftoff.")
	return path
}

func importAll(t *testing.T, path string) {
	t.Helper()
	for _, name := range []string{"launch-window", "fuel-budget", "mission-quiz"} {
		out := mustAuthor(t, "lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", example(name))
		if !strings.Contains(out, "added") {
			t.Errorf("import of %s: %q", name, out)
		}
	}
}

func open(t *testing.T, path string) *sql.DB {
	t.Helper()
	d, _, err := db.Inspect(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func count(t *testing.T, path, query string, args ...any) int {
	t.Helper()
	var n int
	if err := open(t, path).QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return n
}

func sameTree(t *testing.T, got, want string) {
	t.Helper()
	read := func(dir string) map[string]string {
		out := map[string]string{}
		filepath.WalkDir(dir, func(p string, e fs.DirEntry, err error) error {
			if err == nil && !e.IsDir() {
				b, _ := os.ReadFile(p)
				rel, _ := filepath.Rel(dir, p)
				out[filepath.ToSlash(rel)] = string(b)
			}
			return err
		})
		return out
	}
	g, w := read(got), read(want)
	if len(g) != len(w) {
		t.Errorf("%s has %d files, %s has %d", got, len(g), want, len(w))
	}
	for name, content := range w {
		if g[name] != content {
			t.Errorf("%s differs from %s", filepath.Join(got, name), filepath.Join(want, name))
		}
	}
}

func TestAuthorALibrary(t *testing.T) {
	path := library(t)
	importAll(t, path)

	d := open(t, path)
	if problems, err := db.Validate(context.Background(), d); err != nil || len(problems) > 0 {
		t.Fatal(problems, err)
	}
	for query, want := range map[string]int{
		`SELECT count(*) FROM lesson`:                                                          3,
		`SELECT count(*) FROM lesson WHERE uuid IN (?, ?, ?)`:                                  3,
		`SELECT count(*) FROM starter_file`:                                                    5,
		`SELECT count(*) FROM starter_file WHERE is_hidden = 1`:                                1,
		`SELECT count(*) FROM starter_file WHERE is_readonly = 1`:                              2,
		`SELECT count(*) FROM solution_file`:                                                   2,
		`SELECT count(*) FROM code_lesson WHERE expected_output IS NOT NULL`:                   1,
		`SELECT count(*) FROM quiz_answer WHERE is_correct = 1`:                                2,
		`SELECT count(*) FROM lesson_topic`:                                                    4,
		`SELECT count(*) FROM lesson WHERE type = 'type_choice' AND code_last_mod IS NULL`:     1,
		`SELECT count(*) FROM lesson WHERE type <> 'type_choice' AND code_last_mod = last_mod`: 2,
	} {
		var args []any
		if strings.Contains(query, "IN (?") {
			for _, s := range []string{"launch-window", "fuel-budget", "mission-quiz"} {
				args = append(args, authoring.LessonUUID("learn-launches", "1-countdown", s))
			}
		}
		var n int
		if err := d.QueryRow(query, args...).Scan(&n); err != nil || n != want {
			t.Errorf("%s = %d, want %d (%v)", query, n, want, err)
		}
	}

	// Importing the same packages again writes nothing.
	before, _ := os.ReadFile(path)
	for _, name := range []string{"launch-window", "fuel-budget", "mission-quiz"} {
		if out := mustAuthor(t, "lesson", path, "--chapter", "1-countdown", example(name), "--course", "learn-launches"); !strings.Contains(out, "unchanged") {
			t.Errorf("a second import of %s: %q", name, out)
		}
	}
	if code, out, _ := author(t, "course", path, "--slug", "learn-launches", "--title", "Learn Launches", "--kind", "Course",
		"--short", "Write the code that flies Apogee's rockets.", "--description", "A course of invented lessons."); code != 0 || !strings.Contains(out, "unchanged") {
		t.Errorf("the same course again: %d %q", code, out)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("importing the same lessons again changed the library")
	}

	// Exporting gives back the packages, byte for byte, and importing them changes nothing.
	out := filepath.Join(t.TempDir(), "export")
	if msg := mustAuthor(t, "export", path, "--course", "learn-launches", out); !strings.Contains(msg, "exported 3 lessons") {
		t.Errorf("export: %q", msg)
	}
	for _, name := range []string{"launch-window", "fuel-budget", "mission-quiz"} {
		sameTree(t, filepath.Join(out, "1-countdown", name), example(name))
		if msg := mustAuthor(t, "lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", filepath.Join(out, "1-countdown", name)); !strings.Contains(msg, "unchanged") {
			t.Errorf("re-import of the export of %s: %q", name, msg)
		}
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("re-importing the export changed the library")
	}
	one := filepath.Join(t.TempDir(), "chapter")
	mustAuthor(t, "export", path, "--course", "learn-launches", "--chapter", "1-countdown", one)
	sameTree(t, filepath.Join(one, "fuel-budget"), example("fuel-budget"))
	if code, _, errOut := author(t, "export", path, "--course", "learn-launches", one); code != 1 || !strings.Contains(errOut, "is not empty") {
		t.Errorf("export into a folder with files: %d %q", code, errOut)
	}
}

// copyPackage copies an example package so a test can change it.
func copyPackage(t *testing.T, name string) string {
	t.Helper()
	p, err := authoring.Read(example(name))
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), name)
	if err := p.Write(dir); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestReplaceInPlace(t *testing.T) {
	path := library(t)
	importAll(t, path)
	uuid := authoring.LessonUUID("learn-launches", "1-countdown", "launch-window")
	var created string
	open(t, path).QueryRow(`SELECT created_at FROM lesson WHERE uuid = ?`, uuid).Scan(&created)

	dir := copyPackage(t, "launch-window")
	readme := filepath.Join(dir, "README.md")
	b, _ := os.ReadFile(readme)
	os.WriteFile(readme, append(b, "\nA new closing line.\n"...), 0o644)
	os.WriteFile(filepath.Join(dir, "solution", "main.go"), []byte("package main\n\nimport \"fmt\"\n\nconst windowOpens = 90\n\nfunc main() {\n\tfmt.Println(\"Window opens at T-minus\", windowOpens, \"seconds\")\n}\n"), 0o644)
	out := mustAuthor(t, "lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", dir)
	if !strings.Contains(out, "updated readme, solution_file ("+uuid+")") {
		t.Errorf("import of a changed lesson: %q", out)
	}
	var gotCreated, gotReadme string
	open(t, path).QueryRow(`SELECT created_at, readme FROM lesson WHERE uuid = ?`, uuid).Scan(&gotCreated, &gotReadme)
	if gotCreated != created || !strings.HasSuffix(gotReadme, "A new closing line.\n") {
		t.Errorf("after replacing: created_at %s (was %s), readme ends %q", gotCreated, created, gotReadme[max(0, len(gotReadme)-30):])
	}
	if n := count(t, path, `SELECT count(*) FROM lesson`); n != 3 {
		t.Errorf("%d lessons after replacing one, want 3", n)
	}

	// A lesson made elsewhere, under its own uuid, keeps it when a package replaces it.
	other := library(t)
	exec := func(stmts ...string) {
		d, err := db.Open(other)
		if err != nil {
			t.Fatal(err)
		}
		defer d.Close()
		for _, s := range stmts {
			if _, err := d.Exec(s); err != nil {
				t.Fatalf("%s: %v", s, err)
			}
		}
	}
	chapter := authoring.ChapterUUID("learn-launches", "1-countdown")
	exec(`INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
			VALUES ('made-elsewhere', '`+chapter+`', 0, 'mission-quiz', 'Old quiz', 'type_choice', 1, 5, 'Old.', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL, '2026-01-01T00:00:00Z')`,
		`INSERT INTO quiz_lesson VALUES ('made-elsewhere', 'type_choice', 0)`,
		`INSERT INTO quiz_question VALUES ('made-elsewhere', 0, 'Old?')`,
		`INSERT INTO quiz_answer VALUES ('made-elsewhere', 0, 0, 'Yes', 1), ('made-elsewhere', 0, 1, 'No', 0)`,
		`INSERT INTO progress VALUES ('made-elsewhere', '2026-10-31T10:00:00Z', NULL)`)
	quiz := copyPackage(t, "mission-quiz")
	front := filepath.Join(quiz, "README.md")
	b, _ = os.ReadFile(front)
	os.WriteFile(front, bytes.Replace(b, []byte("position: 2"), []byte("position: 0"), 1), 0o644)
	if out := mustAuthor(t, "lesson", other, "--course", "learn-launches", "--chapter", "1-countdown", quiz); !strings.Contains(out, "(made-elsewhere)") {
		t.Errorf("replacing a lesson made elsewhere: %q", out)
	}
	if n := count(t, other, `SELECT count(*) FROM lesson WHERE uuid = 'made-elsewhere' AND title = 'Mission Check'`); n != 1 {
		t.Error("the lesson made elsewhere was not replaced in place")
	}
	if n := count(t, other, `SELECT count(*) FROM progress WHERE lesson_uuid = 'made-elsewhere'`); n != 1 {
		t.Error("the learner's progress on the replaced lesson is gone")
	}
}

func TestAuthorRefuses(t *testing.T) {
	path := library(t)
	importAll(t, path)
	taken := copyPackage(t, "launch-window")
	front := filepath.Join(taken, "README.md")
	b, _ := os.ReadFile(front)
	os.WriteFile(front, bytes.Replace(bytes.Replace(b, []byte("launch-window"), []byte("second-window"), 1), []byte("position: 0"), []byte("position: 1"), 1), 0o644)
	bad := copyPackage(t, "mission-quiz")
	os.WriteFile(filepath.Join(bad, "quiz.md"), []byte("## Pick one\n\n- [x] A\n- [x] B\n"), 0o644)
	before, _ := os.ReadFile(path)

	for _, tc := range []struct {
		name string
		args []string
		code int
		want string
	}{
		{"a position another lesson has", []string{"lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", taken}, 1, "position 1 of chapter 1-countdown is taken by lesson fuel-budget"},
		{"a broken package", []string{"lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", bad}, 1, `has 2 right answers, want exactly one`},
		{"an unknown course", []string{"lesson", path, "--course", "learn-landings", "--chapter", "1-countdown", example("launch-window")}, 1, "the library has no course learn-landings"},
		{"an unknown chapter", []string{"lesson", path, "--course", "learn-launches", "--chapter", "9-orbit", example("launch-window")}, 1, "course learn-launches has no chapter 9-orbit"},
		{"no chapter flag", []string{"lesson", path, "--course", "learn-launches", example("launch-window")}, 2, "--course and --chapter are required"},
		{"an unknown kind", []string{"course", path, "--slug", "learn-orbits", "--title", "Orbits", "--kind", "Lecture", "--short", "S", "--description", "D"}, 2, `--kind "Lecture" is not Course or Guided Project`},
		{"a bad course slug", []string{"course", path, "--slug", "Learn Orbits", "--title", "Orbits", "--kind", "Course", "--short", "S", "--description", "D"}, 2, "is not lowercase letters"},
		{"a picture in a description", []string{"course", path, "--slug", "learn-orbits", "--title", "Orbits", "--kind", "Course", "--short", "S", "--description", "![orbit](https://example.com/orbit.png)"}, 1, "--description holds pictures"},
		{"a course position taken", []string{"course", path, "--slug", "learn-orbits", "--title", "Orbits", "--kind", "Course", "--short", "S", "--description", "D", "--position", "0"}, 1, "position 0 is taken by course learn-launches"},
		{"a chapter of no course", []string{"chapter", path, "--course", "learn-orbits", "--slug", "1-ellipses", "--title", "Ellipses", "--description", "D"}, 1, "the library has no course learn-orbits"},
		{"an unknown command", []string{"publish", path}, 2, `unknown command "publish"`},
		{"too many arguments", []string{"lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", example("launch-window"), "extra"}, 2, "want 2 arguments"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			code, _, errOut := author(t, tc.args...)
			if code != tc.code || !strings.Contains(errOut, tc.want) {
				t.Errorf("exit %d, stderr %q; want %d and %q", code, errOut, tc.code, tc.want)
			}
		})
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("a refused command changed the library")
	}
}

// A write that would leave the library failing its checks is not made.
func TestAuthorChecksTheLibrary(t *testing.T) {
	path := library(t)
	d, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`PRAGMA foreign_keys = OFF`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO note VALUES ('no-such-lesson', 'Lost.', '2026-11-01T10:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	d.Close()
	code, _, errOut := author(t, "lesson", path, "--course", "learn-launches", "--chapter", "1-countdown", example("launch-window"))
	if code != 1 || !strings.Contains(errOut, "nothing was written") || !strings.Contains(errOut, "foreign key: note") {
		t.Errorf("import into a library that fails its checks: %d %q", code, errOut)
	}
	if n := count(t, path, `SELECT count(*) FROM lesson`); n != 0 {
		t.Error("the refused import left a lesson behind")
	}
}

func TestHelp(t *testing.T) {
	code, out, _ := author(t, "help")
	if code != 0 || !strings.Contains(out, "A lesson package is a folder:") || !strings.Contains(out, "author lesson <file>") {
		t.Errorf("help: %d %q", code, out[:min(len(out), 200)])
	}
}
