package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jobloom/gopherwood/db"
	"github.com/jobloom/gopherwood/internal/lessons"
)

// The fixtures of internal/lessons: real lessons of every type, without pictures.
const (
	codeLesson      = "22b72d79-74ef-46c1-88f4-e0440df0d48e"
	quizLesson      = "5a477eea-341f-4de8-b9f7-8e2dcde75ef6"
	cliLesson       = "bbbe7d5d-5eed-4ceb-884d-07f77ff735b7"
	interviewLesson = "190a30a7-1a43-46d5-bb0a-249344b8e89c"
	courseUUID      = "0b0e6e6e-1111-4222-8333-444455556666"
)

func fixture(t *testing.T, uuid string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "internal", "lessons", "testdata", "lessons", uuid+".json"))
	if err != nil {
		t.Fatal(err)
	}
	obj, err := lessons.DecodeObject(b)
	if err != nil {
		t.Fatal(err)
	}
	return obj
}

// nuxtPage renders v as a page whose Nuxt payload is v, in devalue's flat form.
func nuxtPage(v any) []byte {
	flat := []any{nil}
	var add func(any) int
	add = func(v any) int {
		i := len(flat)
		flat = append(flat, nil)
		switch x := v.(type) {
		case map[string]any:
			refs := make(map[string]int, len(x))
			for k, e := range x {
				refs[k] = add(e)
			}
			flat[i] = refs
		case []any:
			refs := make([]int, len(x))
			for j, e := range x {
				refs[j] = add(e)
			}
			flat[i] = refs
		default:
			flat[i] = x
		}
		return i
	}
	flat[0] = []any{"ShallowReactive", add(v)}
	b, _ := json.Marshal(flat)
	return []byte(`<!DOCTYPE html><html><body><script type="application/json" id="__NUXT_DATA__">` + string(b) + `</script></body></html>`)
}

// site plays boot.dev: a catalog with one Go course, a Python course and a portfolio
// project, and the Go course's lesson pages.
type site struct {
	mu       sync.Mutex
	updated  string     // the Go course's lastUpdated
	chapters [][]string // lesson uuids per chapter
	lessons  map[string]map[string]any
	broken   map[string]int // lesson uuid -> status code its page answers with
	loads    int
}

func newSite(t *testing.T) *site {
	return &site{
		updated:  "2026-10-30T11:00:00-03:00",
		chapters: [][]string{{codeLesson, quizLesson}, {cliLesson}},
		lessons: map[string]map[string]any{
			codeLesson: fixture(t, codeLesson), quizLesson: fixture(t, quizLesson),
			cliLesson: fixture(t, cliLesson), interviewLesson: fixture(t, interviewLesson),
		},
		broken: map[string]int{},
	}
}

func (s *site) outline() []any {
	var chapters []any
	for i, ids := range s.chapters {
		var ls []any
		for _, id := range ids {
			ls = append(ls, map[string]any{"uuid": id, "title": s.lessons[id]["title"], "isRequired": true})
		}
		chapters = append(chapters, map[string]any{"uuid": chapterUUID(i), "title": "Chapter " + string(rune('A'+i)), "lessons": ls})
	}
	return chapters
}

func chapterUUID(i int) string { return "0c0e6e6e-1111-4222-8333-44445555000" + string(rune('0'+i)) }

func (s *site) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.loads++
	switch {
	case r.URL.Path == "/courses":
		var cats []any
		for i := range s.chapters {
			cats = append(cats, map[string]any{"uuid": chapterUUID(i), "slug": string(rune('1'+i)) + "-chapter", "title": "Chapter " + string(rune('A'+i)),
				"description": "About chapter " + string(rune('A'+i)) + ". ![a diagram](https://x/d.png)", "numLessons": json.Number("1")})
		}
		w.Write(nuxtPage(map[string]any{"data": map[string]any{"coursesOverview": []any{
			map[string]any{"uuid": "python-0000", "slug": "learn-python", "title": "Learn Python", "typeDescription": "Course", "language": "python",
				"firstLessonUUID": "", "numLessons": json.Number("10"), "chapters": []any{}, "alternatives": map[string]any{"go": "learn-test-golang"}},
			map[string]any{"uuid": courseUUID, "slug": "learn-test-golang", "title": "Learn Testing in Go", "typeDescription": "Course", "language": "go",
				"shortDescription": "Tests.", "description": "Write tests.", "firstLessonUUID": s.chapters[0][0], "lastUpdated": s.updated,
				"numLessons": json.Number("3"), "chapters": cats, "alternatives": map[string]any{}},
			map[string]any{"uuid": "any-0000", "slug": "build-personal-project-1", "title": "First Personal Project", "typeDescription": "Portfolio Project",
				"language": "any", "numLessons": json.Number("4"), "chapters": []any{}},
		}}}))
	case strings.HasPrefix(r.URL.Path, "/lessons/"):
		id := strings.TrimPrefix(r.URL.Path, "/lessons/")
		if code := s.broken[id]; code != 0 {
			w.WriteHeader(code)
			return
		}
		obj, ok := s.lessons[id]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(nuxtPage(map[string]any{"pinia": map[string]any{"courses": map[string]any{
			"courseProgress": map[string]any{courseUUID: map[string]any{"courseUUID": courseUUID, "chapters": s.outline()}},
			"lessons":        map[string]any{id: map[string]any{"lesson": obj}},
		}}}))
	default:
		http.NotFound(w, r)
	}
}

type env struct {
	t    *testing.T
	site *site
	url  string
	path string
}

func newEnv(t *testing.T) *env {
	s := newSite(t)
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return &env{t: t, site: s, url: ts.URL, path: filepath.Join(t.TempDir(), "data", "gopherwood.sqlite")}
}

// run runs a command against the fake site and returns its output.
func (e *env) run(args ...string) (string, error) {
	var out bytes.Buffer
	args = append(args, "-db", e.path)
	if args[0] == "sync" || args[0] == "check" {
		args = append(args, "-site", e.url, "-delay", "0")
	}
	err := run(context.Background(), args, &out)
	return out.String(), err
}

func (e *env) mustRun(args ...string) string {
	e.t.Helper()
	out, err := e.run(args...)
	if err != nil {
		e.t.Fatalf("%v: %v\n%s", args, err, out)
	}
	return out
}

func (e *env) open() *sql.DB {
	e.t.Helper()
	d, err := db.Open(e.path)
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { d.Close() })
	return d
}

func (e *env) count(query string, args ...any) int {
	e.t.Helper()
	d := e.open()
	defer d.Close()
	var n int
	if err := d.QueryRow(query, args...).Scan(&n); err != nil {
		e.t.Fatalf("%s: %v", query, err)
	}
	return n
}

func contains(t *testing.T, out string, wants ...string) {
	t.Helper()
	for _, w := range wants {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
}

func TestSyncAndCheck(t *testing.T) {
	e := newEnv(t)
	// The command-line lesson needs the address of your own server: the source says 'override'.
	e.site.lessons[cliLesson]["lessonDataCLI"].(map[string]any)["cliData"].(map[string]any)["baseURLDefault"] = "override"

	// A first sync makes the database and adds everything.
	out := e.mustRun("sync")
	contains(t, out, "boot.dev lists 1 go courses", "+ learn-test-golang › Chapter A › ", "lessons   3 added", "file size:")
	if n := e.count(`SELECT count(*) FROM lesson`); n != 3 {
		t.Errorf("%d lessons, want 3", n)
	}
	if e.count(`SELECT count(*) FROM chapter WHERE description LIKE '%![%'`) != 0 {
		t.Error("a picture was left in a chapter description")
	}

	// A second sync loads the catalog and the outline, and writes nothing.
	before, _ := os.ReadFile(e.path)
	e.site.loads = 0
	out = e.mustRun("sync")
	contains(t, out, "up to date", "lessons   0 added, 0 changed, 0 loaded again and unchanged, 3 known current")
	if e.site.loads != 2 {
		t.Errorf("the second sync loaded %d pages, want 2", e.site.loads)
	}
	if after, _ := os.ReadFile(e.path); !bytes.Equal(before, after) {
		t.Error("a sync with nothing to do changed the file")
	}
	if e.count(`SELECT count(*) FROM cli_lesson WHERE lesson_uuid = ? AND base_url_default IS NULL AND asks_for_base_url = 1`, cliLesson) != 1 {
		t.Error("'override' was not stored as asks_for_base_url")
	}
	out = e.mustRun("check")
	contains(t, out, "ask for the address of your own server (asks_for_base_url): 1\n  learn-test-golang › Chapter B › "+str(e.site.lessons[cliLesson]["title"]))
	contains(t, out, "integrity: foreign keys", "learn-test-golang", "the database holds everything", "build-personal-project-1 (Portfolio Project, 4 lessons)",
		"learn-python names learn-test-golang as its go version: among the go courses")

	// boot.dev changes the quiz, adds the interview, puts the quiz first and drops the
	// command-line lesson.
	quiz := e.site.lessons[quizLesson]
	quiz["lastMod"] = time.Now().UTC().Format(time.RFC3339)
	quiz["lessonDataMultipleChoice"].(map[string]any)["readme"] = "# Changed\n\nNew text with a [video](https://youtu.be/x)."
	e.site.updated = time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	e.site.chapters = [][]string{{quizLesson, codeLesson}, {interviewLesson}}

	out = e.mustRun("check", "-quick")
	contains(t, out, "lessons the database lacks:\n  learn-test-golang › Chapter B › ", "may have changed", "no longer on boot.dev")
	out = e.mustRun("check")
	contains(t, out, "lessons that changed on boot.dev:\n  learn-test-golang › Chapter A › "+str(quiz["title"])+": readme, last_mod")

	out = e.mustRun("sync")
	contains(t, out, "+ learn-test-golang › Chapter B › ", "~ learn-test-golang › Chapter A › "+str(quiz["title"])+": readme, last_mod",
		"lessons   1 added, 1 changed, 1 loaded again and unchanged", "no longer on boot.dev, kept in the database")
	for _, tc := range []struct {
		uuid     string
		chapter  int
		position int
	}{{quizLesson, 0, 0}, {codeLesson, 0, 1}, {interviewLesson, 1, 0}, {cliLesson, 1, 1}} {
		if e.count(`SELECT count(*) FROM lesson WHERE uuid = ? AND chapter_uuid = ? AND position = ?`, tc.uuid, chapterUUID(tc.chapter), tc.position) != 1 {
			t.Errorf("%s is not at chapter %d #%d", tc.uuid, tc.chapter, tc.position)
		}
	}
	if e.count(`SELECT count(*) FROM lesson WHERE uuid = ? AND readme LIKE '%youtu%'`, quizLesson) != 0 {
		t.Error("the link to a video was kept")
	}
	out = e.mustRun("check")
	contains(t, out, "in the database, no longer on boot.dev")
}

func TestSyncReportsWhatFails(t *testing.T) {
	e := newEnv(t)
	e.site.broken[cliLesson] = http.StatusNotFound
	out, err := e.run("sync")
	if err == nil || !strings.Contains(err.Error(), "could not be synced") {
		t.Fatalf("sync: err = %v", err)
	}
	contains(t, out, "could not be synced:", cliLesson, "lessons   2 added")
	delete(e.site.broken, cliLesson)
	out = e.mustRun("sync")
	contains(t, out, "1 new", "lessons   1 added")
}

func TestSyncLimit(t *testing.T) {
	e := newEnv(t)
	out := e.mustRun("sync", "-limit", "1")
	contains(t, out, "lessons   1 added", "2 lessons left for the next run")
	out = e.mustRun("sync")
	contains(t, out, "lessons   2 added")
}

func TestRun(t *testing.T) {
	for _, tc := range []struct {
		args []string
		ok   bool
		want string
	}{
		{[]string{"help"}, true, "sync check [flags]"},
		{[]string{"frobnicate"}, false, ""},
		{[]string{"check", "-db", filepath.Join(t.TempDir(), "none.sqlite"), "-offline"}, false, ""},
		{[]string{"sync", "extra"}, false, ""},
	} {
		var out bytes.Buffer
		err := run(context.Background(), tc.args, &out)
		if (err == nil) != tc.ok || !strings.Contains(out.String(), tc.want) {
			t.Errorf("run %v: err = %v, output %q", tc.args, err, out.String())
		}
	}
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// rows returns every column of every lesson but one, to show they did not change.
func (e *env) rows(except string) string {
	e.t.Helper()
	d := e.open()
	defer d.Close()
	r, err := d.Query(`SELECT uuid, id, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod,
		coalesce(code_last_mod, ''), synced_at FROM lesson WHERE uuid <> ? ORDER BY uuid`, except)
	if err != nil {
		e.t.Fatal(err)
	}
	defer r.Close()
	var b strings.Builder
	for r.Next() {
		vals := make([]any, 14)
		ptrs := make([]any, 14)
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := r.Scan(ptrs...); err != nil {
			e.t.Fatal(err)
		}
		fmt.Fprintln(&b, vals...)
	}
	return b.String()
}

// A lesson stored with something the stripping rules now remove, here a widget, is loaded
// again and rewritten by a plain sync; no other lesson is touched.
func TestSyncRestripsStoredText(t *testing.T) {
	e := newEnv(t)
	e.mustRun("sync")
	d := e.open()
	if _, err := d.Exec("UPDATE lesson SET readme = readme || '\n\n```widget utf8-text\n{\"text\": \"A\"}\n```\n' WHERE uuid = ?", quizLesson); err != nil {
		t.Fatal(err)
	}
	d.Close()
	others := e.rows(quizLesson)

	out, err := e.run("check")
	if err == nil {
		t.Fatal("check passed a database with a widget left in it")
	}
	contains(t, out, "widgets left in lesson.readme of "+quizLesson, "lessons that changed on boot.dev:\n  learn-test-golang › Chapter A › "+str(e.site.lessons[quizLesson]["title"])+": readme")

	out = e.mustRun("sync")
	contains(t, out, "loading 1 with text the stripping rules now remove", "~ learn-test-golang › Chapter A › "+str(e.site.lessons[quizLesson]["title"])+": readme",
		"lessons   0 added, 1 changed, 0 loaded again and unchanged, 2 known current")
	if e.count("SELECT count(*) FROM lesson WHERE readme LIKE '%```widget%'") != 0 {
		t.Error("the widget is still there")
	}
	if e.rows(quizLesson) != others {
		t.Error("the other lessons changed")
	}
	e.mustRun("check")
}
