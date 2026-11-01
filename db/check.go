package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// typeTables are the per-type tables and the lesson types each one is for.
var typeTables = []struct {
	table string
	types []string
}{
	{"code_lesson", []string{"type_code", "type_code_tests"}},
	{"quiz_lesson", []string{"type_choice"}},
	{"cli_lesson", []string{"type_cli"}},
	{"github_lesson", []string{"type_github_checks"}},
	{"interview_lesson", []string{"type_interview_chat"}},
}

// Problems are what Validate found wrong, one line each.
type Problems []string

// Err returns nil when there are no problems, and otherwise an error that lists them.
func (p Problems) Err() error {
	if len(p) == 0 {
		return nil
	}
	return errors.New("the library failed its checks:\n  " + strings.Join(p, "\n  "))
}

// Querier is what Validate reads through: a *sql.DB, or a *sql.Tx to check a write before it
// is committed.
type Querier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Validate runs the checks docs/library-format.md says a library must pass before the app
// opens it, and returns one line for each problem:
//
//  1. application_id is 1196447556 and user_version is this format's version;
//  2. quick_check is ok and foreign_key_check finds nothing;
//  3. every lesson has exactly one row in the table for its type, of the matching type;
//  4. every quiz question has exactly one right answer;
//  5. every cli_step has its command or request row, matching its kind;
//  6. every solution_file solves an editable starter file of its lesson: one neither hidden
//     nor read-only.
//
// The other checks run only once the first passes, since a file of another format may not have
// the tables they read, and only on a file quick_check finds whole. Validate writes nothing. An
// error means a check could not run at all.
func Validate(ctx context.Context, d Querier) (Problems, error) {
	var p Problems
	add := func(format string, args ...any) { p = append(p, fmt.Sprintf(format, args...)) }

	var app, version int
	if err := d.QueryRowContext(ctx, `SELECT (SELECT application_id FROM pragma_application_id), (SELECT user_version FROM pragma_user_version)`).Scan(&app, &version); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		add("the file is not an SQLite database SQLite can read: %v", err)
		return p, nil
	}
	switch {
	case app != ApplicationID:
		add("application_id is %d, not %d: the file is not a Gopherwood library", app, ApplicationID)
	case version < Version:
		add("user_version is %d, not %d: the library is of an older format; migrating brings it up to date", version, Version)
	case version > Version:
		add("user_version is %d, not %d: the library is of a newer format than this program knows", version, Version)
	}
	if len(p) > 0 {
		return p, nil
	}

	if err := eachRow(ctx, d, `SELECT quick_check FROM pragma_quick_check`, func(r *sql.Rows) error {
		var msg string
		if err := r.Scan(&msg); err != nil {
			return err
		}
		if msg == "ok" {
			return nil
		}
		for line := range strings.SplitSeq(msg, "\n") {
			if line = strings.TrimSpace(line); line != "" && !strings.HasPrefix(line, "*** in database") {
				add("quick_check: %s", line)
			}
		}
		return nil
	}); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		add("quick_check: %v", err) // too damaged for the check to finish
	}
	if len(p) > 0 {
		return p, nil // a damaged file: the checks below would only fail to read it
	}

	if err := eachRow(ctx, d, `SELECT "table", rowid, parent FROM pragma_foreign_key_check ORDER BY 1, 2`, func(r *sql.Rows) error {
		var table, parent string
		var rowid sql.NullInt64
		if err := r.Scan(&table, &rowid, &parent); err != nil {
			return err
		}
		add("foreign key: %s row %d points at a missing %s row", table, rowid.Int64, parent)
		return nil
	}); err != nil {
		return nil, fmt.Errorf("foreign_key_check: %w", err)
	}

	var counts []string
	for _, t := range typeTables {
		counts = append(counts, fmt.Sprintf("(SELECT count(*) FROM %s x WHERE x.lesson_uuid = l.uuid)", t.table))
	}
	if err := eachRow(ctx, d, `SELECT l.uuid, l.type, `+strings.Join(counts, ", ")+` FROM lesson l ORDER BY l.uuid`, func(r *sql.Rows) error {
		var uuid, typ string
		n := make([]int, len(typeTables))
		dest := []any{&uuid, &typ}
		for i := range n {
			dest = append(dest, &n[i])
		}
		if err := r.Scan(dest...); err != nil {
			return err
		}
		for i, t := range typeTables {
			want := 0
			for _, x := range t.types {
				if x == typ {
					want = 1
				}
			}
			if n[i] != want {
				add("lesson %s (%s) has %d %s rows, want %d", uuid, typ, n[i], t.table, want)
			}
		}
		return nil
	}); err != nil {
		return nil, fmt.Errorf("per-type rows: %w", err)
	}

	if err := eachRow(ctx, d, `SELECT lesson_uuid, position, n FROM (
			SELECT q.lesson_uuid, q.position, (SELECT count(*) FROM quiz_answer a
				WHERE a.lesson_uuid = q.lesson_uuid AND a.question_position = q.position AND a.is_correct = 1) AS n
			FROM quiz_question q)
		WHERE n <> 1 ORDER BY 1, 2`, func(r *sql.Rows) error {
		var uuid string
		var position, n int
		if err := r.Scan(&uuid, &position, &n); err != nil {
			return err
		}
		add("quiz question %d of lesson %s has %d right answers, want 1", position, uuid, n)
		return nil
	}); err != nil {
		return nil, fmt.Errorf("quiz answers: %w", err)
	}

	if err := eachRow(ctx, d, `SELECT s.lesson_uuid, s.position, s.kind FROM cli_step s
		WHERE (s.kind = 'command' AND NOT EXISTS (SELECT 1 FROM cli_command c WHERE c.lesson_uuid = s.lesson_uuid AND c.step_position = s.position AND c.step_kind = s.kind))
		   OR (s.kind = 'http' AND NOT EXISTS (SELECT 1 FROM cli_http_request h WHERE h.lesson_uuid = s.lesson_uuid AND h.step_position = s.position AND h.step_kind = s.kind))
		ORDER BY 1, 2`, func(r *sql.Rows) error {
		var uuid, kind string
		var position int
		if err := r.Scan(&uuid, &position, &kind); err != nil {
			return err
		}
		detail := map[string]string{"command": "cli_command", "http": "cli_http_request"}[kind]
		add("cli_step %d of lesson %s (%s) has no %s row", position, uuid, kind, detail)
		return nil
	}); err != nil {
		return nil, fmt.Errorf("command-line steps: %w", err)
	}

	if err := eachRow(ctx, d, `SELECT s.lesson_uuid, s.name FROM solution_file s
		WHERE NOT EXISTS (SELECT 1 FROM starter_file f
			WHERE f.lesson_uuid = s.lesson_uuid AND f.name = s.name AND f.is_hidden = 0 AND f.is_readonly = 0)
		ORDER BY 1, 2`, func(r *sql.Rows) error {
		var uuid, name string
		if err := r.Scan(&uuid, &name); err != nil {
			return err
		}
		add("solution_file %s of lesson %s solves no editable starter file", name, uuid)
		return nil
	}); err != nil {
		return nil, fmt.Errorf("solution files: %w", err)
	}
	return p, nil
}

func eachRow(ctx context.Context, d Querier, query string, fn func(*sql.Rows) error) error {
	rows, err := d.QueryContext(ctx, query)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		if err := fn(rows); err != nil {
			return err
		}
	}
	return errors.Join(rows.Err(), rows.Close())
}
