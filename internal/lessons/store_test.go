package lessons

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/jobloom/gopherwood/db"
)

func newDB(t *testing.T) *sql.DB {
	t.Helper()
	d, _ := newDBFile(t)
	return d
}

func newDBFile(t *testing.T) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gopherwood.sqlite")
	d, err := db.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d, path
}

const synced = "2026-10-31T15:00:00Z"

// outline is a course to write: its chapters, each with the uuids of its lessons in order.
type outline struct {
	course   Course
	chapters []Chapter
	lessons  [][]string
	required map[string]bool // lessons that are optional are false here; the rest are required
}

// course makes an outline of one course from fixture uuids.
func course(uuid, slug string, chapters ...[]string) outline {
	o := outline{course: Course{UUID: uuid, Slug: slug, Title: slug, Kind: "Course", ShortDescription: "Short.", Description: "Long."}, lessons: chapters}
	for i := range chapters {
		id := uuid + "-ch" + string(rune('a'+i))
		o.chapters = append(o.chapters, Chapter{UUID: id, Slug: string(rune('1'+i)) + "-chapter", Title: "Chapter " + string(rune('A'+i))})
	}
	return o
}

// write writes courses as a sync does, in one transaction, and returns what Put did to each
// lesson and what PlaceLessons reported.
func write(t *testing.T, d *sql.DB, objs map[string]map[string]any, courses ...outline) (puts map[string]Change, moved, gone []string) {
	t.Helper()
	puts = map[string]Change{}
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	var want []Course
	for _, o := range courses {
		want = append(want, o.course)
	}
	if _, err := PlaceCourses(tx, want); err != nil {
		t.Fatal(err)
	}
	for _, o := range courses {
		if _, err := PlaceChapters(tx, o.course.UUID, o.chapters); err != nil {
			t.Fatal(err)
		}
		places := map[string]Placement{}
		for ci, ids := range o.lessons {
			for li, id := range ids {
				places[id] = Placement{ChapterUUID: o.chapters[ci].UUID, Position: int64(li), Required: o.required == nil || o.required[id]}
			}
		}
		m, g, err := PlaceLessons(tx, o.course.UUID, places)
		if err != nil {
			t.Fatal(err)
		}
		moved, gone = append(moved, m...), append(gone, g...)
		for _, ids := range o.lessons {
			for _, id := range ids {
				rec, err := Build(objs[id])
				if err != nil {
					t.Fatalf("%s: %v", id, err)
				}
				p := places[id]
				rec.Lesson.ChapterUUID, rec.Lesson.Position, rec.Lesson.Required, rec.Lesson.SyncedAt = p.ChapterUUID, p.Position, p.Required, synced
				ch, _, err := Put(tx, rec, func(u string) bool { return slices.Contains(g, u) })
				if err != nil {
					t.Fatalf("%s: %v", id, err)
				}
				puts[id] = ch
			}
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	return puts, moved, gone
}

func mustCheck(t *testing.T, d *sql.DB) {
	t.Helper()
	if p, err := db.Validate(context.Background(), d); err != nil || len(p) > 0 {
		t.Fatal(p, err)
	}
	if err := db.SearchCheck(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	if left, err := MediaLeft(d); err != nil || len(left) > 0 {
		t.Fatalf("media left: %v %v", left, err)
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

// everyFixture lays all fixtures out in one course, a chapter per type.
func everyFixture(t *testing.T, objs map[string]map[string]any) outline {
	byType := map[string][]string{}
	for _, id := range sortedKeys(objs) {
		typ := str(objs[id]["type"])
		byType[typ] = append(byType[typ], id)
	}
	var chapters [][]string
	for _, typ := range sortedKeys(byType) {
		chapters = append(chapters, byType[typ])
	}
	return course("c-all", "all-fixtures", chapters...)
}

func TestWriteEveryFixture(t *testing.T) {
	d, path := newDBFile(t)
	objs := fixtures(t)
	o := everyFixture(t, objs)
	puts, _, _ := write(t, d, objs, o)
	for id, ch := range puts {
		if ch != Added {
			t.Errorf("%s: %v, want Added", id, ch)
		}
	}
	mustCheck(t, d)
	if n := count(t, d, `SELECT count(*) FROM lesson`); n != len(objs) {
		t.Errorf("%d lessons, want %d", n, len(objs))
	}
	for _, table := range PartTables {
		if table == "solution_file" { // boot.dev lessons carry no solutions
			continue
		}
		if count(t, d, `SELECT count(*) FROM `+table) == 0 {
			t.Errorf("no %s rows", table)
		}
	}
	if n := count(t, d, `SELECT count(*) FROM lesson_search WHERE lesson_search MATCH 'trailers'`); n == 0 {
		t.Error("search finds nothing for 'trailers'")
	}

	// Writing the same lessons again changes nothing, down to the file's bytes.
	before, _ := os.ReadFile(path)
	puts, moved, gone := write(t, d, objs, o)
	for id, ch := range puts {
		if ch != Same {
			t.Errorf("rewrite of %s: %v, want Same", id, ch)
		}
	}
	if len(moved)+len(gone) > 0 {
		t.Errorf("rewrite moved %v, gone %v", moved, gone)
	}
	if after, _ := os.ReadFile(path); !bytes.Equal(before, after) {
		t.Error("writing the same lessons again changed the file")
	}
}

func TestChangedLessonKeepsItsID(t *testing.T) {
	d := newDB(t)
	objs := fixtures(t)
	const quiz = "5a477eea-341f-4de8-b9f7-8e2dcde75ef6"
	o := course("c1", "one", []string{quiz})
	write(t, d, objs, o)
	id := count(t, d, `SELECT id FROM lesson WHERE uuid = ?`, quiz)

	data := objs[quiz]["lessonDataMultipleChoice"].(map[string]any)
	data["readme"] = "# Rewritten\n\nA zanzibar of a lesson."
	q := data["questions"].([]any)[0].(map[string]any)
	q["question"] = "A new question?"
	objs[quiz]["lastMod"] = "2026-11-01T10:00:00-03:00"
	tx, _ := d.Begin()
	rec, err := Build(objs[quiz])
	if err != nil {
		t.Fatal(err)
	}
	rec.Lesson.ChapterUUID, rec.Lesson.Position, rec.Lesson.Required, rec.Lesson.SyncedAt = o.chapters[0].UUID, 0, true, synced
	ch, diff, err := Put(tx, rec, nil)
	if err != nil {
		t.Fatal(err)
	}
	tx.Commit()
	if ch != Changed || !slices.Contains(diff, "readme") || !slices.Contains(diff, "last_mod") || !slices.Contains(diff, "quiz_question") {
		t.Errorf("Put = %v %v", ch, diff)
	}
	if got := count(t, d, `SELECT id FROM lesson WHERE uuid = ?`, quiz); got != id {
		t.Errorf("id %d became %d", id, got)
	}
	if count(t, d, `SELECT count(*) FROM lesson_search WHERE lesson_search MATCH 'zanzibar'`) != 1 {
		t.Error("search does not find the new readme")
	}
	if got := count(t, d, `SELECT count(*) FROM lesson WHERE last_mod = '2026-11-01T13:00:00Z'`); got != 1 {
		t.Error("last_mod not rewritten in UTC")
	}
	mustCheck(t, d)
}

func TestTypeChange(t *testing.T) {
	d := newDB(t)
	objs := fixtures(t)
	const interview, quiz = "190a30a7-1a43-46d5-bb0a-249344b8e89c", "5a477eea-341f-4de8-b9f7-8e2dcde75ef6"
	o := course("c1", "one", []string{interview})
	write(t, d, objs, o)
	if _, err := d.Exec(`INSERT INTO progress VALUES (?, '2026-10-31T12:00:00Z', NULL)`, interview); err != nil {
		t.Fatal(err)
	}

	// boot.dev turns the interview into a quiz.
	obj := objs[interview]
	obj["type"] = "type_choice"
	obj["lessonDataMultipleChoice"] = objs[quiz]["lessonDataMultipleChoice"]
	delete(obj, "lessonDataInterviewChat")
	puts, _, _ := write(t, d, objs, o)
	if puts[interview] != Changed {
		t.Errorf("Put = %v, want Changed", puts[interview])
	}
	if count(t, d, `SELECT count(*) FROM interview_lesson`) != 0 || count(t, d, `SELECT count(*) FROM quiz_lesson WHERE lesson_uuid = ?`, interview) != 1 {
		t.Error("the per-type rows did not follow the type")
	}
	mustCheck(t, d)
}

func TestReorderMoveAndGone(t *testing.T) {
	d := newDB(t)
	objs := fixtures(t)
	ids := sortedKeys(objs)
	a, b, c, x, y := ids[0], ids[1], ids[2], ids[3], ids[4]
	write(t, d, objs, course("c1", "one", []string{a, b, c}, []string{x, y}))
	if _, err := d.Exec(`INSERT INTO progress VALUES (?, '2026-10-31T12:00:00Z', NULL)`, y); err != nil {
		t.Fatal(err)
	}

	// boot.dev swaps a and c, moves b to the second chapter, and drops y.
	_, moved, gone := write(t, d, objs, course("c1", "one", []string{c, a}, []string{b, x}))
	if !slices.Equal(gone, []string{y}) {
		t.Errorf("gone = %v, want [%s]", gone, y)
	}
	slices.Sort(moved)
	if want := []string{a, b, c, x, y}; !slices.Equal(moved, sorted(want)) {
		t.Errorf("moved = %v, want %v", moved, sorted(want))
	}
	for _, tc := range []struct {
		uuid     string
		chapter  string
		position int
	}{{c, "c1-cha", 0}, {a, "c1-cha", 1}, {b, "c1-chb", 0}, {x, "c1-chb", 1}, {y, "c1-chb", 2}} {
		if n := count(t, d, `SELECT count(*) FROM lesson WHERE uuid = ? AND chapter_uuid = ? AND position = ?`, tc.uuid, tc.chapter, tc.position); n != 1 {
			t.Errorf("%s is not at %s #%d", tc.uuid, tc.chapter, tc.position)
		}
	}
	if count(t, d, `SELECT count(*) FROM lesson`) != 5 {
		t.Error("a lesson was deleted")
	}
	mustCheck(t, d)
}

func TestGoneLessonGivesUpItsSlug(t *testing.T) {
	d := newDB(t)
	objs := fixtures(t)
	ids := sortedKeys(objs)
	old, replacement := ids[0], ids[1]
	write(t, d, objs, course("c1", "one", []string{old}))
	objs[replacement]["slug"] = objs[old]["slug"] // boot.dev replaced the lesson under the same slug
	write(t, d, objs, course("c1", "one", []string{replacement}))
	var slug string
	d.QueryRow(`SELECT slug FROM lesson WHERE uuid = ?`, old).Scan(&slug)
	if want := str(objs[old]["slug"]) + "-" + old[:8]; slug != want {
		t.Errorf("the old lesson's slug is %q, want %q", slug, want)
	}
	if count(t, d, `SELECT count(*) FROM lesson WHERE uuid = ? AND slug = ?`, replacement, str(objs[old]["slug"])) != 1 {
		t.Error("the new lesson did not get its slug")
	}
	mustCheck(t, d)
}

func TestPlaceCoursesReorders(t *testing.T) {
	d := newDB(t)
	objs := fixtures(t)
	ids := sortedKeys(objs)
	one, two, three := course("c1", "one", []string{ids[0]}), course("c2", "two", []string{ids[1]}), course("c3", "three", []string{ids[2]})
	write(t, d, objs, one, two, three)
	write(t, d, objs, three, one) // two is gone from the catalog
	for _, tc := range []struct {
		uuid     string
		position int
	}{{"c3", 0}, {"c1", 1}, {"c2", 2}} {
		if count(t, d, `SELECT count(*) FROM course WHERE uuid = ? AND position = ?`, tc.uuid, tc.position) != 1 {
			t.Errorf("course %s is not at %d", tc.uuid, tc.position)
		}
	}
	mustCheck(t, d)
}

func sorted(s []string) []string {
	s = slices.Clone(s)
	slices.Sort(s)
	return s
}
