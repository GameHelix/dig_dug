package lessons

// Writing the lesson tables of db/schema.sql.
//
//   - A lesson is never deleted, so the progress, attempts, notes and code that point at it stay
//     valid. One that boot.dev no longer lists keeps its row and moves after the listed lessons
//     of its chapter.
//   - A lesson row is written with INSERT ... ON CONFLICT(uuid) DO UPDATE, which keeps its id,
//     the key of the search index. A lesson whose parts changed has its typed rows deleted
//     (deleting the type's root row cascades to the rest), its row updated, and the new rows
//     inserted, all in the caller's transaction.
//   - Nothing that is the same is written again, so the committed file only changes when the
//     lessons do.
//   - Positions are unique, so a reorder parks the rows first (position + 1000000) and then
//     gives each its place.

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jobloom/gopherwood/internal/media"
)

// TableCols lists, for each table that holds part of a lesson, its columns in the order a
// Row's values come in.
var TableCols = map[string][]string{
	"lesson_topic":               {"lesson_uuid", "topic"},
	"code_lesson":                {"lesson_uuid", "lesson_type", "prog_lang", "expected_output"},
	"starter_file":               {"lesson_uuid", "name", "position", "content", "is_hidden", "is_readonly"},
	"quiz_lesson":                {"lesson_uuid", "lesson_type", "contains_complete_dir"},
	"quiz_question":              {"lesson_uuid", "position", "question"},
	"quiz_answer":                {"lesson_uuid", "question_position", "position", "answer", "is_correct"},
	"cli_lesson":                 {"lesson_uuid", "lesson_type", "base_url_default", "use_agent_prompt", "contains_complete_dir"},
	"cli_lesson_os":              {"lesson_uuid", "os"},
	"cli_step":                   {"lesson_uuid", "position", "kind", "description", "no_penalty_on_fail", "sleep_after_ms"},
	"cli_command":                {"lesson_uuid", "step_position", "step_kind", "command", "stdout_filter_tmdl"},
	"cli_command_variable":       {"lesson_uuid", "step_position", "position", "name", "regex"},
	"cli_command_test":           {"lesson_uuid", "step_position", "position", "kind", "exit_code", "lines_gt", "jq_query", "jq_input"},
	"cli_command_test_text":      {"lesson_uuid", "step_position", "test_position", "test_kind", "position", "text"},
	"cli_command_test_jq_result": {"lesson_uuid", "step_position", "test_position", "test_kind", "position", "operator", "value_type", "bool_value", "int_value", "string_value"},
	"cli_http_request":           {"lesson_uuid", "step_position", "step_kind", "method", "full_url", "follow_redirects", "basic_auth_username", "basic_auth_password", "body_kind", "body_json"},
	"cli_http_header":            {"lesson_uuid", "step_position", "position", "name", "value"},
	"cli_http_form_field":        {"lesson_uuid", "step_position", "body_kind", "position", "name", "value"},
	"cli_http_body_variable":     {"lesson_uuid", "step_position", "position", "name", "json_path", "regex"},
	"cli_http_header_variable":   {"lesson_uuid", "step_position", "position", "name", "header", "regex"},
	"cli_http_test":              {"lesson_uuid", "step_position", "position", "kind", "status_code", "text", "field_name", "field_value", "json_path", "json_operator", "value_type", "bool_value", "int_value", "string_value"},
	"github_lesson":              {"lesson_uuid", "lesson_type", "showcase_repo", "contains_complete_dir"},
	"github_step":                {"lesson_uuid", "position", "kind", "branch_name", "file_path", "pr_base_owner", "pr_base_repo", "pr_base_branch", "pr_compare_branch", "workflow_name", "workflow_status"},
	"github_file_text":           {"lesson_uuid", "step_position", "step_kind", "position", "text"},
	"github_log_text":            {"lesson_uuid", "step_position", "step_kind", "job", "position", "text"},
	"interview_lesson":           {"lesson_uuid", "lesson_type", "student_prompt", "acceptance_criteria"},
}

// PartTables are the tables of TableCols, parents before children.
var PartTables = []string{
	"lesson_topic",
	"code_lesson", "starter_file",
	"quiz_lesson", "quiz_question", "quiz_answer",
	"cli_lesson", "cli_lesson_os", "cli_step", "cli_command", "cli_command_variable", "cli_command_test",
	"cli_command_test_text", "cli_command_test_jq_result", "cli_http_request", "cli_http_header",
	"cli_http_form_field", "cli_http_body_variable", "cli_http_header_variable", "cli_http_test",
	"github_lesson", "github_step", "github_file_text", "github_log_text",
	"interview_lesson",
}

// rootTables are the tables a lesson's parts hang from: deleting a lesson's rows in them
// removes all its parts.
var rootTables = []string{"lesson_topic", "code_lesson", "quiz_lesson", "cli_lesson", "github_lesson", "interview_lesson"}

// park is added to positions to move rows out of the way before they get their new places.
const park = 1000000

// Change says what a write did.
type Change int

const (
	Same Change = iota
	Added
	Changed
)

// Counts holds how many rows a write left the same, added and changed, by Change.
type Counts [3]int

// Course is a row of the course table.
type Course struct {
	UUID, Slug, Title, Kind, ShortDescription, Description string
	Position                                               int64
}

// Chapter is a row of the chapter table.
type Chapter struct {
	UUID, CourseUUID         string
	Position                 int64
	Slug, Title, Description string
}

// Placement is where a listed lesson belongs.
type Placement struct {
	ChapterUUID string
	Position    int64
	Required    bool
}

// Querier is what reads need: a *sql.DB or a *sql.Tx.
type Querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

// ---- Courses and chapters ----

// PlaceCourses writes the listed courses in the order given, numbered from 0. Courses that are
// not listed (boot.dev no longer has them) keep their rows and follow the listed ones.
func PlaceCourses(tx *sql.Tx, want []Course) (Counts, error) {
	var n Counts
	cur, err := Courses(tx)
	if err != nil {
		return n, err
	}
	want = slices.Clone(want)
	listed := map[string]bool{}
	slugs := map[string]bool{}
	for i := range want {
		want[i].Position = int64(i)
		listed[want[i].UUID] = true
		slugs[want[i].Slug] = true
	}
	final := want
	for _, c := range cur {
		if !listed[c.UUID] {
			c.Position = int64(len(final))
			if slugs[c.Slug] {
				c.Slug += "-" + short(c.UUID) // its slug now belongs to a listed course
			}
			final = append(final, c)
		}
	}
	byUUID := map[string]Course{}
	for _, c := range cur {
		byUUID[c.UUID] = c
	}
	parked := false
	for _, c := range final {
		if old, ok := byUUID[c.UUID]; ok && (old.Position != c.Position || old.Slug != c.Slug) {
			parked = true
		}
	}
	if parked {
		if _, err := tx.Exec(`UPDATE course SET position = position + ?, slug = slug || '~parked'`, park); err != nil {
			return n, fmt.Errorf("parking courses: %w", err)
		}
	}
	for _, c := range final {
		old, ok := byUUID[c.UUID]
		switch {
		case !ok:
			n[Added]++
		case old == c && !parked:
			n[Same]++
			continue
		case old == c:
			n[Same]++
		default:
			n[Changed]++
		}
		if _, err := tx.Exec(`INSERT INTO course (uuid, slug, title, kind, short_description, description, position) VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(uuid) DO UPDATE SET slug = excluded.slug, title = excluded.title, kind = excluded.kind,
				short_description = excluded.short_description, description = excluded.description, position = excluded.position`,
			c.UUID, c.Slug, c.Title, c.Kind, c.ShortDescription, c.Description, c.Position); err != nil {
			return n, fmt.Errorf("course %s: %w", c.Slug, err)
		}
	}
	return n, nil
}

// PlaceChapters writes a course's listed chapters in the order given, numbered from 0.
// Chapters of the course that are not listed keep their rows and follow the listed ones.
func PlaceChapters(tx *sql.Tx, courseUUID string, want []Chapter) (Counts, error) {
	var n Counts
	cur, err := Chapters(tx, `WHERE course_uuid = ?`, courseUUID)
	if err != nil {
		return n, err
	}
	want = slices.Clone(want)
	listed := map[string]bool{}
	slugs := map[string]bool{}
	ids := []any{courseUUID}
	for i := range want {
		want[i].CourseUUID, want[i].Position = courseUUID, int64(i)
		listed[want[i].UUID] = true
		slugs[want[i].Slug] = true
		ids = append(ids, want[i].UUID)
	}
	moving, err := Chapters(tx, `WHERE course_uuid <> ? AND uuid IN (`+marks(len(ids)-1)+`)`, ids...)
	if err != nil {
		return n, err
	}
	final := want
	for _, c := range cur {
		if !listed[c.UUID] {
			c.Position = int64(len(final))
			if slugs[c.Slug] {
				c.Slug += "-" + short(c.UUID)
			}
			final = append(final, c)
		}
	}
	byUUID := map[string]Chapter{}
	for _, c := range append(cur, moving...) {
		byUUID[c.UUID] = c
	}
	parked := len(moving) > 0
	for _, c := range final {
		if old, ok := byUUID[c.UUID]; ok && (old.Position != c.Position || old.Slug != c.Slug) {
			parked = true
		}
	}
	if parked {
		if _, err := tx.Exec(`UPDATE chapter SET position = position + ?, slug = slug || '~parked' WHERE course_uuid = ?`, park, courseUUID); err != nil {
			return n, fmt.Errorf("parking chapters: %w", err)
		}
	}
	for _, c := range final {
		old, ok := byUUID[c.UUID]
		switch {
		case !ok:
			n[Added]++
		case old == c && !parked:
			n[Same]++
			continue
		case old == c:
			n[Same]++
		default:
			n[Changed]++
		}
		if _, err := tx.Exec(`INSERT INTO chapter (uuid, course_uuid, position, slug, title, description) VALUES (?, ?, ?, ?, ?, ?)
			ON CONFLICT(uuid) DO UPDATE SET course_uuid = excluded.course_uuid, position = excluded.position, slug = excluded.slug,
				title = excluded.title, description = excluded.description`,
			c.UUID, c.CourseUUID, c.Position, c.Slug, c.Title, c.Description); err != nil {
			return n, fmt.Errorf("chapter %s: %w", c.Slug, err)
		}
	}
	return n, nil
}

// PlaceLessons puts the lessons already in the database where want says, for the chapters of
// one course: listed lessons take their place, and those that are not listed stay in their
// chapter, after the listed ones. Lessons not in the database yet are inserted later by Put,
// into the places left for them. It returns the uuids of the lessons that moved and of those
// no longer listed.
func PlaceLessons(tx *sql.Tx, courseUUID string, want map[string]Placement) (moved, gone []string, err error) {
	type cur struct {
		uuid, chapter, slug string
		position            int64
		required            bool
	}
	ids := []any{courseUUID}
	for _, u := range sortedKeys(want) {
		ids = append(ids, u)
	}
	rows, err := tx.Query(`SELECT uuid, chapter_uuid, slug, position, required FROM lesson
		WHERE chapter_uuid IN (SELECT uuid FROM chapter WHERE course_uuid = ?) OR uuid IN (`+marks(len(want))+`)
		ORDER BY chapter_uuid, position`, ids...)
	if err != nil {
		return nil, nil, fmt.Errorf("placing lessons: %w", err)
	}
	var all []cur
	for rows.Next() {
		var c cur
		var req int64
		if err := rows.Scan(&c.uuid, &c.chapter, &c.slug, &c.position, &req); err != nil {
			rows.Close()
			return nil, nil, err
		}
		c.required = req == 1
		all = append(all, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	listedIn := map[string]int64{}              // chapter -> number of listed places in it
	listedSlugs := map[string]map[string]bool{} // chapter -> slugs of listed lessons in it
	for _, p := range want {
		listedIn[p.ChapterUUID] = max(listedIn[p.ChapterUUID], p.Position+1)
	}
	for _, c := range all {
		if p, ok := want[c.uuid]; ok {
			if listedSlugs[p.ChapterUUID] == nil {
				listedSlugs[p.ChapterUUID] = map[string]bool{}
			}
			listedSlugs[p.ChapterUUID][c.slug] = true
		}
	}
	final := map[string]Placement{}
	for u, p := range want {
		final[u] = p
	}
	next := map[string]int64{}
	var rename []string
	for _, c := range all {
		if _, ok := want[c.uuid]; ok {
			continue
		}
		final[c.uuid] = Placement{ChapterUUID: c.chapter, Position: listedIn[c.chapter] + next[c.chapter], Required: c.required}
		next[c.chapter]++
		gone = append(gone, c.uuid)
		if listedSlugs[c.chapter][c.slug] {
			rename = append(rename, c.uuid)
		}
	}
	for _, u := range rename {
		if _, err := tx.Exec(`UPDATE lesson SET slug = slug || '-' || substr(uuid, 1, 8) WHERE uuid = ?`, u); err != nil {
			return nil, nil, fmt.Errorf("lesson %s: %w", u, err)
		}
	}

	parked := false
	for _, c := range all {
		if f := final[c.uuid]; f.ChapterUUID != c.chapter || f.Position != c.position {
			parked = true
			moved = append(moved, c.uuid)
		}
	}
	if parked {
		if _, err := tx.Exec(`UPDATE lesson SET position = position + ? WHERE chapter_uuid IN (SELECT uuid FROM chapter WHERE course_uuid = ?)`, park, courseUUID); err != nil {
			return nil, nil, fmt.Errorf("parking lessons: %w", err)
		}
	}
	for _, c := range all {
		f := final[c.uuid]
		if !parked && f.ChapterUUID == c.chapter && f.Position == c.position && f.Required == c.required {
			continue
		}
		if _, err := tx.Exec(`UPDATE lesson SET chapter_uuid = ?, position = ?, required = ? WHERE uuid = ?`,
			f.ChapterUUID, f.Position, boolInt(f.Required), c.uuid); err != nil {
			return nil, nil, fmt.Errorf("lesson %s: %w", c.uuid, err)
		}
	}
	return moved, gone, nil
}

// ---- Lessons ----

// Put writes one lesson, which PlaceLessons has already given its place if it was in the
// database: a new lesson is inserted; one whose row or parts differ is rewritten in place,
// keeping its id; one that is the same is left alone. It returns what differed. A lesson that
// is no longer listed and holds the slug this one needs in its chapter is renamed out of the
// way when renamable says so.
func Put(tx *sql.Tx, rec Record, renamable func(uuid string) bool) (Change, []string, error) {
	r := rec.Lesson
	cur, exists, err := Get(tx, r.UUID)
	if err != nil {
		return Same, nil, err
	}
	var diff []string
	partsChanged := true
	if exists {
		diff = LessonDiff(cur, r)
		old, err := ReadParts(tx, r.UUID)
		if err != nil {
			return Same, nil, err
		}
		tables := PartsDiff(old, rec.Rows)
		partsChanged = len(tables) > 0
		diff = append(diff, tables...)
		if len(diff) == 0 {
			return Same, nil, nil
		}
	}
	var holder string
	err = tx.QueryRow(`SELECT uuid FROM lesson WHERE chapter_uuid = ? AND slug = ? AND uuid <> ?`, r.ChapterUUID, r.Slug, r.UUID).Scan(&holder)
	switch {
	case errors.Is(err, sql.ErrNoRows):
	case err != nil:
		return Same, nil, err
	case renamable != nil && renamable(holder):
		if _, err := tx.Exec(`UPDATE lesson SET slug = slug || '-' || substr(uuid, 1, 8) WHERE uuid = ?`, holder); err != nil {
			return Same, nil, err
		}
	default:
		return Same, nil, fmt.Errorf("lesson %s already has the slug %q in this chapter", holder, r.Slug)
	}
	if exists && partsChanged {
		for _, t := range rootTables {
			if _, err := tx.Exec(`DELETE FROM `+t+` WHERE lesson_uuid = ?`, r.UUID); err != nil {
				return Same, nil, fmt.Errorf("clearing %s: %w", t, err)
			}
		}
	}
	if _, err := tx.Exec(`INSERT INTO lesson (uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(uuid) DO UPDATE SET chapter_uuid = excluded.chapter_uuid, position = excluded.position, slug = excluded.slug,
			title = excluded.title, type = excluded.type, required = excluded.required, difficulty = excluded.difficulty,
			readme = excluded.readme, created_at = excluded.created_at, last_mod = excluded.last_mod,
			code_last_mod = excluded.code_last_mod, synced_at = excluded.synced_at`,
		r.UUID, r.ChapterUUID, r.Position, r.Slug, r.Title, r.Type, boolInt(r.Required), r.Difficulty, r.Readme,
		r.CreatedAt, r.LastMod, r.CodeLastMod, r.SyncedAt); err != nil {
		return Same, nil, fmt.Errorf("lesson row: %w", err)
	}
	if partsChanged {
		if err := insertParts(tx, rec.Rows); err != nil {
			return Same, nil, err
		}
	}
	if !exists {
		return Added, nil, nil
	}
	return Changed, diff, nil
}

// Touch records that a lesson was found unchanged on boot.dev at syncedAt.
func Touch(tx *sql.Tx, uuid, syncedAt string) error {
	if _, err := tx.Exec(`UPDATE lesson SET synced_at = ? WHERE uuid = ?`, syncedAt, uuid); err != nil {
		return fmt.Errorf("lesson %s: %w", uuid, err)
	}
	return nil
}

func insertParts(tx *sql.Tx, rows []Row) error {
	stmts := map[string]*sql.Stmt{}
	defer func() {
		for _, s := range stmts {
			s.Close()
		}
	}()
	for _, r := range rows {
		s, ok := stmts[r.Table]
		if !ok {
			cols := TableCols[r.Table]
			var err error
			if s, err = tx.Prepare(`INSERT INTO ` + r.Table + ` (` + strings.Join(cols, ", ") + `) VALUES (` + marks(len(cols)) + `)`); err != nil {
				return fmt.Errorf("%s: %w", r.Table, err)
			}
			stmts[r.Table] = s
		}
		if _, err := s.Exec(r.Vals...); err != nil {
			return fmt.Errorf("%s %v: %w", r.Table, r.Vals[1:], err)
		}
	}
	return nil
}

// ReadParts reads a lesson's rows from every part table.
func ReadParts(q Querier, uuid string) ([]Row, error) {
	var out []Row
	for _, t := range PartTables {
		cols := TableCols[t]
		rows, err := q.Query(`SELECT `+strings.Join(cols, ", ")+` FROM `+t+` WHERE lesson_uuid = ?`, uuid)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", t, err)
		}
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				rows.Close()
				return nil, err
			}
			out = append(out, Row{Table: t, Vals: vals})
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// PartsDiff names the tables in which two sets of a lesson's rows differ.
func PartsDiff(a, b []Row) []string {
	render := func(rows []Row) map[string]string {
		lines := map[string][]string{}
		for _, r := range rows {
			lines[r.Table] = append(lines[r.Table], renderVals(r.Vals))
		}
		out := map[string]string{}
		for t, l := range lines {
			sort.Strings(l)
			out[t] = strings.Join(l, "\n")
		}
		return out
	}
	ra, rb := render(a), render(b)
	var diff []string
	for _, t := range PartTables {
		if ra[t] != rb[t] {
			diff = append(diff, t)
		}
	}
	return diff
}

func renderVals(vals []any) string {
	parts := make([]string, len(vals))
	for i, v := range vals {
		switch v := v.(type) {
		case nil:
			parts[i] = "N"
		case int64:
			parts[i] = "i" + strconv.FormatInt(v, 10)
		case int:
			parts[i] = "i" + strconv.Itoa(v)
		case bool:
			parts[i] = "i" + strconv.FormatInt(boolInt(v), 10)
		case string:
			parts[i] = "s" + strconv.Quote(v)
		case []byte:
			parts[i] = "s" + strconv.Quote(string(v))
		default:
			parts[i] = fmt.Sprintf("?%v", v)
		}
	}
	return strings.Join(parts, "|")
}

// Get reads a lesson row.
func Get(q Querier, uuid string) (Lesson, bool, error) {
	var r Lesson
	var req int64
	err := q.QueryRow(`SELECT uuid, chapter_uuid, position, slug, title, type, required, difficulty, readme, created_at, last_mod, code_last_mod, synced_at
		FROM lesson WHERE uuid = ?`, uuid).
		Scan(&r.UUID, &r.ChapterUUID, &r.Position, &r.Slug, &r.Title, &r.Type, &req, &r.Difficulty, &r.Readme, &r.CreatedAt, &r.LastMod, &r.CodeLastMod, &r.SyncedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return r, false, nil
	}
	if err != nil {
		return r, false, fmt.Errorf("reading lesson %s: %w", uuid, err)
	}
	r.Required = req == 1
	return r, true, nil
}

// LessonDiff names the fields in which two rows of the same lesson differ, synced_at aside.
func LessonDiff(a, b Lesson) []string {
	var d []string
	for _, f := range []struct {
		differs bool
		name    string
	}{
		{a.ChapterUUID != b.ChapterUUID, "chapter"},
		{a.Position != b.Position, "position"},
		{a.Required != b.Required, "required"},
		{a.Slug != b.Slug, "slug"},
		{a.Title != b.Title, "title"},
		{a.Type != b.Type, "type"},
		{a.Difficulty != b.Difficulty, "difficulty"},
		{a.Readme != b.Readme, "readme"},
		{a.CreatedAt != b.CreatedAt, "created_at"},
		{a.LastMod != b.LastMod, "last_mod"},
		{a.CodeLastMod != b.CodeLastMod, "code_last_mod"},
	} {
		if f.differs {
			d = append(d, f.name)
		}
	}
	return d
}

// ---- Reads ----

// Stored is what a sync needs to know of a lesson in the database.
type Stored struct {
	UUID, ChapterUUID, CourseUUID string
	Position                      int64
	Required                      bool
	Slug, Title, LastMod          string
	SyncedAt                      time.Time
}

// LoadAll reads every lesson in the database.
func LoadAll(q Querier) (map[string]Stored, error) {
	rows, err := q.Query(`SELECT l.uuid, l.chapter_uuid, c.course_uuid, l.position, l.required, l.slug, l.title, l.last_mod, l.synced_at
		FROM lesson l JOIN chapter c ON c.uuid = l.chapter_uuid`)
	if err != nil {
		return nil, fmt.Errorf("reading lessons: %w", err)
	}
	defer rows.Close()
	out := map[string]Stored{}
	for rows.Next() {
		var l Stored
		var req int64
		var synced string
		if err := rows.Scan(&l.UUID, &l.ChapterUUID, &l.CourseUUID, &l.Position, &req, &l.Slug, &l.Title, &l.LastMod, &synced); err != nil {
			return nil, err
		}
		l.Required = req == 1
		if l.SyncedAt, err = time.Parse(time.RFC3339, synced); err != nil {
			return nil, fmt.Errorf("lesson %s: synced_at %q: %w", l.UUID, synced, err)
		}
		out[l.UUID] = l
	}
	return out, rows.Err()
}

// Courses reads every course, in order.
func Courses(q Querier) ([]Course, error) {
	rows, err := q.Query(`SELECT uuid, slug, title, kind, short_description, description, position FROM course ORDER BY position`)
	if err != nil {
		return nil, fmt.Errorf("reading courses: %w", err)
	}
	defer rows.Close()
	var out []Course
	for rows.Next() {
		var c Course
		if err := rows.Scan(&c.UUID, &c.Slug, &c.Title, &c.Kind, &c.ShortDescription, &c.Description, &c.Position); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// Chapters reads the chapters a WHERE clause picks, in order.
func Chapters(q Querier, where string, args ...any) ([]Chapter, error) {
	rows, err := q.Query(`SELECT uuid, course_uuid, position, slug, title, description FROM chapter `+where+` ORDER BY course_uuid, position`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading chapters: %w", err)
	}
	defer rows.Close()
	var out []Chapter
	for rows.Next() {
		var c Chapter
		if err := rows.Scan(&c.UUID, &c.CourseUUID, &c.Position, &c.Slug, &c.Title, &c.Description); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// proseColumns are the text columns that hold prose, where no picture, video or widget may be
// left. lesson is true where the key is a lesson's uuid.
var proseColumns = []struct {
	table, key, col string
	lesson          bool
}{
	{"course", "slug", "title", false}, {"course", "slug", "short_description", false}, {"course", "slug", "description", false},
	{"chapter", "uuid", "title", false}, {"chapter", "uuid", "description", false},
	{"lesson", "uuid", "title", true}, {"lesson", "uuid", "readme", true},
	{"quiz_question", "lesson_uuid", "question", true}, {"quiz_answer", "lesson_uuid", "answer", true},
	{"cli_step", "lesson_uuid", "description", true},
	{"interview_lesson", "lesson_uuid", "student_prompt", true}, {"interview_lesson", "lesson_uuid", "acceptance_criteria", true},
}

// unstripped calls found for every prose value in which media.Strip would still find something
// to remove.
func unstripped(q Querier, found func(table, col, key string, lesson bool)) error {
	for _, c := range proseColumns {
		rows, err := q.Query(`SELECT ` + c.key + `, ` + c.col + ` FROM ` + c.table)
		if err != nil {
			return fmt.Errorf("reading %s.%s: %w", c.table, c.col, err)
		}
		for rows.Next() {
			var key, text string
			if err := rows.Scan(&key, &text); err != nil {
				rows.Close()
				return err
			}
			if _, st := media.Strip(text); st.Total() > 0 {
				found(c.table, c.col, key, c.lesson)
			}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
	}
	return nil
}

// MediaLeft lists the prose values in which media.Strip would still find a picture, a video
// or a widget.
func MediaLeft(q Querier) ([]string, error) {
	var out []string
	err := unstripped(q, func(table, col, key string, _ bool) {
		out = append(out, fmt.Sprintf("%s.%s of %s", table, col, key))
	})
	return out, err
}

// Unstripped returns the lessons whose stored text still holds something media.Strip removes,
// as happens when its rules grow. A sync loads them again, so they are rewritten under the
// current rules.
func Unstripped(q Querier) (map[string]bool, error) {
	out := map[string]bool{}
	err := unstripped(q, func(_, _, key string, lesson bool) {
		if lesson {
			out[key] = true
		}
	})
	return out, err
}

// ---- Helpers ----

// DecodeObject decodes a JSON object, keeping numbers exact.
func DecodeObject(b []byte) (map[string]any, error) {
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}
	if m == nil {
		return nil, errors.New("not a JSON object")
	}
	return m, nil
}

// marshal encodes v as compact JSON with map keys sorted and <, > and & left as they are.
func marshal(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// marks returns n comma-separated placeholders.
func marks(n int) string {
	if n == 0 {
		return "NULL"
	}
	return strings.TrimSuffix(strings.Repeat("?, ", n), ", ")
}

func short(uuid string) string {
	if len(uuid) > 8 {
		return uuid[:8]
	}
	return uuid
}

// UTC formats t as the database keeps times: RFC 3339 in UTC with a trailing Z, to the second.
func UTC(t time.Time) string { return t.UTC().Truncate(time.Second).Format(time.RFC3339) }

// sortedKeys returns the keys of m in order.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}
