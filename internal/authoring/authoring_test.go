package authoring

// The packages in testdata/packages are invented lessons for a fictional space startup,
// Apogee: one of each type.

import (
	"bytes"
	"context"
	"database/sql"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/jobloom/gopherwood/db"
	"github.com/jobloom/gopherwood/internal/lessons"
)

var examples = []string{"launch-window", "fuel-budget", "mission-quiz"}

func example(name string) string { return filepath.Join("testdata", "packages", name) }

func TestUUIDv5(t *testing.T) {
	dns := mustUUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
	if got := uuidV5(dns, "www.example.com"); got != "2ed6657d-e927-568b-95e1-2665a8aea6a2" {
		t.Errorf("uuidV5(DNS, www.example.com) = %s, want RFC 4122's 2ed6657d-e927-568b-95e1-2665a8aea6a2", got)
	}
	a := LessonUUID("learn-launches", "1-countdown", "launch-window")
	if a != LessonUUID("learn-launches", "1-countdown", "launch-window") || a == LessonUUID("learn-launches", "2-orbit", "launch-window") {
		t.Error("a lesson's uuid must depend on its slugs, and on nothing else")
	}
	if a[14] != '5' {
		t.Errorf("%s is not a version 5 uuid", a)
	}
}

// files reads every file under dir, by path.
func files(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(dir, func(p string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		b, err := os.ReadFile(p)
		rel, _ := filepath.Rel(dir, p)
		out[filepath.ToSlash(rel)] = string(b)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func sameFiles(t *testing.T, got, want string) {
	t.Helper()
	g, w := files(t, got), files(t, want)
	for name, content := range w {
		if g[name] != content {
			t.Errorf("%s differs:\n%q\nwant\n%q", name, g[name], content)
		}
	}
	for name := range g {
		if _, ok := w[name]; !ok {
			t.Errorf("%s was not in the package", name)
		}
	}
}

func TestReadWriteRoundTrip(t *testing.T) {
	for _, name := range examples {
		t.Run(name, func(t *testing.T) {
			p, err := Read(example(name))
			if err != nil {
				t.Fatal(err)
			}
			out := filepath.Join(t.TempDir(), name)
			if err := p.Write(out); err != nil {
				t.Fatal(err)
			}
			sameFiles(t, out, example(name))
		})
	}
	p, _ := Read(example("fuel-budget"))
	var flags []string
	for _, f := range p.Starter {
		flags = append(flags, f.Name+map[bool]string{true: " hidden", false: ""}[f.Hidden]+map[bool]string{true: " read-only", false: ""}[f.ReadOnly])
	}
	if want := []string{"fuel.go", "fuel_test.go read-only", "limits.go read-only", "vehicle.go hidden"}; !reflect.DeepEqual(flags, want) {
		t.Errorf("fuel-budget's starter files = %q, want %q", flags, want)
	}
	if len(p.Solution) != 1 || p.Solution[0].Name != "fuel.go" {
		t.Errorf("fuel-budget's solution = %+v", p.Solution)
	}
}

// Into a library and back: Record, then Load, gives the same package and the same files.
func TestRecordAndLoad(t *testing.T) {
	d, err := db.Create(filepath.Join(t.TempDir(), "apogee.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	for _, s := range []string{
		`INSERT INTO course VALUES ('c', 'learn-launches', 'Learn Launches', 'Course', 'Launch code.', 'An invented course.', 0)`,
		`INSERT INTO chapter VALUES ('ch', 'c', 0, '1-countdown', 'Countdown', '')`,
	} {
		if _, err := d.Exec(s); err != nil {
			t.Fatal(err)
		}
	}
	times := Times{Created: "2026-11-01T10:00:00Z", Modified: "2026-11-01T10:00:00Z", Synced: "2026-11-01T10:00:00Z"}
	for _, name := range examples {
		p, err := Read(example(name))
		if err != nil {
			t.Fatal(err)
		}
		uuid := LessonUUID("learn-launches", "1-countdown", p.Slug)
		tx, _ := d.Begin()
		if _, _, err := lessons.Put(tx, p.Record(uuid, "ch", times), nil); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
		back, err := Load(d, uuid)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(back, p) {
			t.Errorf("%s came back as\n%+v\nwant\n%+v", name, back, p)
		}
		out := filepath.Join(t.TempDir(), name)
		if err := back.Write(out); err != nil {
			t.Fatal(err)
		}
		sameFiles(t, out, example(name))
	}
	if problems, err := db.Validate(context.Background(), d); err != nil || len(problems) > 0 {
		t.Error(problems, err)
	}
	var codeLastMod sql.NullString
	d.QueryRow(`SELECT code_last_mod FROM lesson WHERE slug = 'mission-quiz'`).Scan(&codeLastMod)
	if codeLastMod.Valid {
		t.Error("a quiz has a code_last_mod")
	}
}

// edit copies an example package and changes it: files maps a path to its new content, or ""
// to remove it.
func edit(t *testing.T, name string, files map[string]string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	src := example(name)
	err := filepath.WalkDir(src, func(p string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		target := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(target), 0o755)
		return os.WriteFile(target, b, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
	for name, content := range files {
		target := filepath.Join(dir, filepath.FromSlash(name))
		if content == "" {
			os.Remove(target)
			continue
		}
		os.MkdirAll(filepath.Dir(target), 0o755)
		if err := os.WriteFile(target, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func front(lines ...string) string {
	return "---\n" + strings.Join(lines, "\n") + "\n---\n# A lesson\n"
}

var goodFront = []string{"slug: launch-window", "title: The Launch Window", "type: code", "position: 0", "difficulty: 10", "topics: constants, printing"}

func with(i int, line string) []string {
	f := append([]string(nil), goodFront...)
	f[i] = line
	return f
}

func TestReadRefuses(t *testing.T) {
	for _, tc := range []struct {
		name    string
		example string
		files   map[string]string
		want    string
	}{
		{"no front matter", "launch-window", map[string]string{"README.md": "# A lesson\n"}, "must start with a front matter block"},
		{"front matter not closed", "launch-window", map[string]string{"README.md": "---\nslug: x\n"}, `no closing "---" line`},
		{"a missing key", "launch-window", map[string]string{"README.md": front(goodFront[:5]...)}, "front matter has no topics"},
		{"an unknown key", "launch-window", map[string]string{"README.md": front(append(goodFront, "author: me")...)}, `front matter line "author: me" is not one of`},
		{"keys out of order", "launch-window", map[string]string{"README.md": front(goodFront[1], goodFront[0], goodFront[2], goodFront[3], goodFront[4], goodFront[5])}, "front matter must read exactly"},
		{"a bad slug", "launch-window", map[string]string{"README.md": front(with(0, "slug: Launch_Window")...)}, `slug "Launch_Window" is not lowercase`},
		{"an unknown type", "launch-window", map[string]string{"README.md": front(with(2, "type: video")...)}, `type "video" is not code, code_tests or quiz`},
		{"a negative position", "launch-window", map[string]string{"README.md": front(with(3, "position: -1")...)}, `position "-1" is not a whole number from 0 up`},
		{"no difficulty", "launch-window", map[string]string{"README.md": front(with(4, "difficulty: 0")...)}, `difficulty "0" is not a whole number from 1 up`},
		{"topics out of order", "launch-window", map[string]string{"README.md": front(with(5, "topics: printing, constants")...)}, "topics: constants, printing"},
		{"a topic twice", "launch-window", map[string]string{"README.md": front(with(5, "topics: printing, printing")...)}, "topics lists a topic twice"},
		{"blanks after a value", "launch-window", map[string]string{"README.md": front(with(1, "title: The Launch Window ")...)}, "front matter must read exactly"},
		{"a picture in the readme", "launch-window", map[string]string{"README.md": front(goodFront...) + "\n![rocket](https://example.com/rocket.png)\n"}, "README.md holds 1 pictures"},
		{"no expected output", "launch-window", map[string]string{"expected_output.txt": ""}, "a code lesson needs expected_output.txt"},
		{"a solution missing", "launch-window", map[string]string{"solution/main.go": ""}, "solution/ has no main.go, a file the learner edits"},
		{"a solution for a test", "fuel-budget", map[string]string{"solution/fuel_test.go": "package main\n"}, "solution/fuel_test.go solves no file the learner edits"},
		{"a solution for a read-only file", "fuel-budget", map[string]string{"solution/limits.go": "package main\n"}, "solution/limits.go solves no file the learner edits"},
		{"a list naming a missing file", "fuel-budget", map[string]string{"readonly.txt": "limits.go\nnothing.go\n"}, "readonly.txt lists nothing.go, which is not in starter/"},
		{"a list out of order", "fuel-budget", map[string]string{"starter/aaa.go": "package main\n", "readonly.txt": "limits.go\naaa.go\n"}, "readonly.txt must list each file once, in alphabetical order"},
		{"a test in readonly.txt", "fuel-budget", map[string]string{"readonly.txt": "fuel_test.go\nlimits.go\n"}, "readonly.txt lists fuel_test.go, a _test.go file"},
		{"an empty list", "fuel-budget", map[string]string{"hidden.txt": "\n"}, "hidden.txt: every line is one file name"},
		{"tests without a test file", "fuel-budget", map[string]string{"starter/fuel_test.go": "", "solution/fuel_test.go": ""}, "a code_tests lesson needs at least one _test.go file"},
		{"nothing to edit", "launch-window", map[string]string{"readonly.txt": "main.go\n", "solution/main.go": ""}, "starter/ has no file the learner edits"},
		{"an expected output in a code_tests lesson", "fuel-budget", map[string]string{"expected_output.txt": "x\n"}, "expected_output.txt does not belong in a code_tests lesson's package"},
		{"a stray file", "launch-window", map[string]string{"notes.md": "to do\n"}, "notes.md does not belong in a code lesson's package"},
		{"text that is not UTF-8", "launch-window", map[string]string{"starter/logo.bin": "\xff\xfe\x00"}, "logo.bin is not UTF-8 text"},
		{"two right answers", "mission-quiz", map[string]string{"quiz.md": "## Pick one\n\n- [x] A\n- [x] B\n"}, `question "Pick one" has 2 right answers, want exactly one`},
		{"no right answer", "mission-quiz", map[string]string{"quiz.md": "## Pick one\n\n- [ ] A\n- [ ] B\n"}, `question "Pick one" has 0 right answers`},
		{"an answer twice", "mission-quiz", map[string]string{"quiz.md": "## Pick one\n\n- [x] A\n- [ ] A\n"}, `question "Pick one" has the answer "A" twice`},
		{"one answer only", "mission-quiz", map[string]string{"quiz.md": "## Pick one\n\n- [x] A\n"}, `question "Pick one" has fewer than two answers`},
		{"a quiz not written exactly", "mission-quiz", map[string]string{"quiz.md": "## Pick one\n- [x] A\n- [ ] B\n"}, "quiz.md: it must read exactly"},
		{"an answer before any question", "mission-quiz", map[string]string{"quiz.md": "- [x] A\n"}, "comes before any question"},
		{"a link to a video in an answer", "mission-quiz", map[string]string{"quiz.md": "## Watch?\n\n- [x] [the launch](https://youtu.be/abc) at noon\n- [ ] No\n"}, "question 1, answer 1 holds"},
		{"code files in a quiz", "mission-quiz", map[string]string{"starter/main.go": "package main\n"}, "starter does not belong in a quiz lesson's package"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Read(edit(t, tc.example, tc.files))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Errorf("Read: err = %v, want it to say %q", err, tc.want)
			}
		})
	}
}

func TestIgnoresDotFiles(t *testing.T) {
	dir := edit(t, "launch-window", map[string]string{".DS_Store": "x", "starter/.notes": "x"})
	p, err := Read(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Starter) != 1 {
		t.Errorf("starter files %+v, want main.go only", p.Starter)
	}
	if err := p.Write(dir); err == nil || !bytes.Contains([]byte(err.Error()), []byte("not empty")) {
		t.Errorf("Write into a folder that has files: err = %v", err)
	}
}
