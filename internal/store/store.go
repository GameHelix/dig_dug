// Package store reads and writes one lesson of a library: its row in the lesson table and its
// rows in the tables that hold its parts (db/schema.sql), in the caller's transaction.
//
//   - Put never deletes a lesson row. It writes the row with INSERT ... ON CONFLICT(uuid) DO
//     UPDATE, which keeps the row's id, the key of the search index, and keeps valid the
//     progress, attempts, notes and code that point at the lesson.
//   - A lesson whose parts changed has its part rows deleted (deleting its rows in the root
//     tables cascades to the rest), its row updated, and the new part rows inserted.
//   - Nothing that is the same is written again, so a library's file changes only when its
//     lessons do.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Lesson is a row of the lesson table, without its id.
type Lesson struct {
	UUID, ChapterUUID  string
	Position           int64
	Slug, Title, Type  string
	Required           bool
	Difficulty         int64
	Readme             string
	CreatedAt, LastMod string
	CodeLastMod        sql.NullString
	SyncedAt           string
}

// Row is a row of one of a lesson's part tables, its values in the order of the table's
// columns: int64 for INTEGER, string for TEXT, nil for NULL.
type Row struct {
	Table string
	Vals  []any
}

// Record is everything a library keeps of one lesson.
type Record struct {
	Lesson Lesson
	Rows   []Row // lesson_topic and the type's tables, parents before children
}

// Querier is what reads need: a *sql.DB or a *sql.Tx.
type Querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

// tableCols lists, for each table that holds part of a lesson, its columns in the order a Row's
// values come in.
var tableCols = map[string][]string{
	"lesson_topic":               {"lesson_uuid", "topic"},
	"code_lesson":                {"lesson_uuid", "lesson_type", "prog_lang", "expected_output"},
	"starter_file":               {"lesson_uuid", "name", "position", "content", "is_hidden", "is_readonly"},
	"solution_file":              {"lesson_uuid", "name", "content"},
	"quiz_lesson":                {"lesson_uuid", "lesson_type", "contains_complete_dir"},
	"quiz_question":              {"lesson_uuid", "position", "question"},
	"quiz_answer":                {"lesson_uuid", "question_position", "position", "answer", "is_correct"},
	"cli_lesson":                 {"lesson_uuid", "lesson_type", "base_url_default", "asks_for_base_url", "use_agent_prompt", "contains_complete_dir"},
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

// partTables are the tables of tableCols, parents before children.
var partTables = []string{
	"lesson_topic",
	"code_lesson", "starter_file", "solution_file",
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

// Put writes one lesson into its chapter: a new lesson is inserted; one whose row or parts
// differ is rewritten in place, keeping its id; one that is the same is left alone. Another
// lesson of the chapter with the same slug is an error.
func Put(tx *sql.Tx, rec Record) error {
	r := rec.Lesson
	cur, exists, err := Get(tx, r.UUID)
	if err != nil {
		return err
	}
	partsChanged := true
	if exists {
		old, err := ReadParts(tx, r.UUID)
		if err != nil {
			return err
		}
		partsChanged = len(PartsDiff(old, rec.Rows)) > 0
		if cur == r && !partsChanged {
			return nil
		}
	}
	var holder string
	err = tx.QueryRow(`SELECT uuid FROM lesson WHERE chapter_uuid = ? AND slug = ? AND uuid <> ?`, r.ChapterUUID, r.Slug, r.UUID).Scan(&holder)
	switch {
	case err == nil:
		return fmt.Errorf("lesson %s already has the slug %q in this chapter", holder, r.Slug)
	case !errors.Is(err, sql.ErrNoRows):
		return err
	}
	if exists && partsChanged {
		for _, t := range rootTables {
			if _, err := tx.Exec(`DELETE FROM `+t+` WHERE lesson_uuid = ?`, r.UUID); err != nil {
				return fmt.Errorf("clearing %s: %w", t, err)
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
		return fmt.Errorf("lesson row: %w", err)
	}
	if partsChanged {
		return insertParts(tx, rec.Rows)
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
			cols, ok := tableCols[r.Table]
			if !ok {
				return fmt.Errorf("%s is not a table of a lesson's parts", r.Table)
			}
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
	for _, t := range partTables {
		cols := tableCols[t]
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
	for _, t := range partTables {
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

// UTC formats t as a library keeps times: RFC 3339 in UTC with a trailing Z, to the second.
func UTC(t time.Time) string { return t.UTC().Truncate(time.Second).Format(time.RFC3339) }

func boolInt(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// marks returns n comma-separated placeholders.
func marks(n int) string {
	return strings.TrimSuffix(strings.Repeat("?, ", n), ", ")
}
