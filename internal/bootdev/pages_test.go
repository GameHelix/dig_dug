package bootdev

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestDecodeNuxt(t *testing.T) {
	// Each entry refers to others by index; -1 stands for undefined.
	raw := `[
		["ShallowReactive", 1],
		{"data": 2, "pinia": 5},
		["Reactive", 3],
		{"list": 4, "when": 11, "gone": 13},
		[6, -1, 7],
		{"courses": 8},
		"a",
		42,
		{"tags": 9, "lookup": 10, "bare": 12, "self": 5},
		["Set", 6, 7],
		["Map", 6, 7],
		["Date", "2026-01-02T03:04:05Z"],
		["null", "k", 6],
		["EmptyRef", "_"]
	]`
	v, err := DecodeNuxt([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	root := v.(map[string]any)
	for _, tc := range []struct {
		path []string
		want any
	}{
		{[]string{"data"}, map[string]any{"list": []any{"a", nil, json.Number("42")}, "when": "2026-01-02T03:04:05Z", "gone": nil}},
		{[]string{"pinia", "courses", "tags"}, []any{"a", json.Number("42")}},
		{[]string{"pinia", "courses", "lookup"}, map[string]any{"a": json.Number("42")}},
		{[]string{"pinia", "courses", "bare"}, map[string]any{"k": "a"}},
	} {
		if got := dig(root, tc.path...); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s = %#v\nwant %#v", strings.Join(tc.path, "."), got, tc.want)
		}
	}
	// A reference back to an enclosing object resolves to that same object.
	if dig(root, "pinia", "courses", "self", "courses", "self", "courses", "tags") == nil {
		t.Error("cyclic reference did not resolve")
	}
}

func TestDecodeNuxtErrors(t *testing.T) {
	for _, raw := range []string{``, `[]`, `{"a": 1}`, `[1, 2`} {
		if _, err := DecodeNuxt([]byte(raw)); err == nil {
			t.Errorf("DecodeNuxt(%q) should fail", raw)
		}
	}
	for _, html := range []string{"<html></html>", `<script id="__NUXT_DATA__">["a"]</script>`} {
		if _, err := PageData([]byte(html)); err == nil {
			t.Errorf("PageData(%q) should fail", html)
		}
	}
}

func readPage(t *testing.T, name string) map[string]any {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	root, err := PageData(b)
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// testdata/courses.html is boot.dev's catalog page cut to five entries: a Go course, a Go
// guided project, a Python course, a language-agnostic portfolio project and a TypeScript
// course that names its Go version.
func TestParseCatalog(t *testing.T) {
	all, err := ParseCatalog(readPage(t, "courses.html"))
	if err != nil {
		t.Fatal(err)
	}
	var slugs []string
	for _, c := range all {
		slugs = append(slugs, c.Slug)
	}
	if want := []string{"learn-golang", "learn-python-beginners", "build-pokedex-cli-golang", "build-personal-project-1", "learn-http-clients-typescript"}; !reflect.DeepEqual(slugs, want) {
		t.Fatalf("slugs = %v, want %v", slugs, want)
	}

	goCourses := OfLanguage(all, "go")
	for i, tc := range []struct {
		slug, kind, first string
		lessons, position int
		updated           string
	}{
		{"learn-golang", "Course", "224252be-adc9-452f-8ed0-0b305b25d0cb", 148, 0, "2026-10-28T13:05:47Z"},
		{"build-pokedex-cli-golang", "Guided Project", "", 13, 1, "2026-10-30T14:09:39Z"},
	} {
		if i >= len(goCourses) {
			t.Fatalf("only %d Go courses", len(goCourses))
		}
		c := goCourses[i]
		if c.Slug != tc.slug || c.Kind != tc.kind || c.Language != "go" || c.NumLessons != tc.lessons || c.Position != tc.position {
			t.Errorf("Go course %d = %s %q lang %s, %d lessons, position %d", i, c.Slug, c.Kind, c.Language, c.NumLessons, c.Position)
		}
		if tc.first != "" && c.FirstLesson != tc.first {
			t.Errorf("%s: first lesson %s", c.Slug, c.FirstLesson)
		}
		if got := c.LastUpdated.Format(time.RFC3339); got != tc.updated {
			t.Errorf("%s: last updated %s, want %s (in UTC)", c.Slug, got, tc.updated)
		}
		if len(c.Chapters) != 2 || c.Chapters[0].Slug == "" || c.Chapters[0].NumLessons == 0 {
			t.Errorf("%s: chapters %+v", c.Slug, c.Chapters)
		}
	}
	if len(goCourses) != 2 {
		t.Errorf("%d Go courses, want 2", len(goCourses))
	}
	ts := all[4]
	if ts.Alternatives["go"] != "learn-http-clients-golang" || ts.Language != "typescript" {
		t.Errorf("TypeScript course alternatives = %v", ts.Alternatives)
	}
	if any := OfLanguage(all, "any"); len(any) != 1 || any[0].Kind != "Portfolio Project" {
		t.Errorf("language-agnostic entries = %+v", any)
	}
}

func TestParseCatalogErrors(t *testing.T) {
	for _, root := range []map[string]any{
		{},
		{"data": map[string]any{"coursesOverview": []any{}}},
		{"data": map[string]any{"coursesOverview": []any{map[string]any{"title": "no uuid"}}}},
	} {
		if _, err := ParseCatalog(root); err == nil {
			t.Errorf("ParseCatalog(%v) should fail", root)
		}
	}
}

// testdata/lesson.html is the page of Learn Go's first lesson, its outline cut to two chapters
// of three lessons and its readme without the picture.
func TestParseLessonPage(t *testing.T) {
	root := readPage(t, "lesson.html")
	outline, err := ParseOutline(root, "3b39d0f6-f944-4f1b-832d-a1daba32eda4")
	if err != nil {
		t.Fatal(err)
	}
	if len(outline) != 2 || len(outline[0].Lessons) != 3 || len(outline[1].Lessons) != 3 {
		t.Fatalf("outline = %+v", outline)
	}
	first := outline[0].Lessons[0]
	if first.UUID != "224252be-adc9-452f-8ed0-0b305b25d0cb" || first.Title != "Learn Go" || !first.Required {
		t.Errorf("first lesson = %+v", first)
	}
	if _, err := ParseOutline(root, "not-a-course"); err == nil {
		t.Error("an outline for another course should not be found")
	}

	l, err := LessonFromPage(root, first.UUID)
	if err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{"type": "type_code", "slug": "1-run-code", "courseSlug": "learn-golang"} {
		if got := str(l[k]); got != want {
			t.Errorf("lesson %s = %q, want %q", k, got, want)
		}
	}
	if _, ok := l["lessonDataCodeOutput"].(map[string]any); !ok {
		t.Error("lesson payload missing")
	}
	if _, err := LessonFromPage(root, outline[0].Lessons[1].UUID); err == nil {
		t.Error("a lesson the page was not made for should not be found")
	}
}

// The client and the parsers together, against a server that serves the saved pages.
func TestCatalogAndLessonPage(t *testing.T) {
	mux := http.NewServeMux()
	for path, file := range map[string]string{"/courses": "courses.html", "/lessons/224252be-adc9-452f-8ed0-0b305b25d0cb": "lesson.html"} {
		b, err := os.ReadFile("testdata/" + file)
		if err != nil {
			t.Fatal(err)
		}
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) { w.Write(b) })
	}
	ts := httptest.NewServer(mux)
	defer ts.Close()
	c, err := New(WithBaseURL(ts.URL), WithDelay(0))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	all, err := c.Catalog(ctx)
	if err != nil || len(all) != 5 {
		t.Fatalf("Catalog: %d courses, %v", len(all), err)
	}
	root, err := c.LessonPage(ctx, all[0].FirstLesson)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := LessonFromPage(root, all[0].FirstLesson); err != nil {
		t.Error(err)
	}
}
