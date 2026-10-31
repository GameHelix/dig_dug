package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// typeTables are the per-type tables, in the order Check counts them, and the lesson types
// each one is for.
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

// Check fails unless the database is whole: no foreign key points nowhere, the file passes
// integrity_check, the full-text index matches the lessons, every lesson has exactly one
// per-type row and it is the one for its type, every quiz question has exactly one right
// answer, and every command-line step has its command or HTTP request. It writes nothing.
func Check(ctx context.Context, d *sql.DB) error {
	var problems []string
	add := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }

	if err := eachRow(ctx, d, `SELECT "table", rowid, parent FROM pragma_foreign_key_check`, func(r *sql.Rows) error {
		var table, parent string
		var rowid sql.NullInt64
		if err := r.Scan(&table, &rowid, &parent); err != nil {
			return err
		}
		add("foreign key: %s row %d points at a missing %s row", table, rowid.Int64, parent)
		return nil
	}); err != nil {
		return fmt.Errorf("foreign_key_check: %w", err)
	}

	var ok string
	if err := d.QueryRowContext(ctx, `PRAGMA integrity_check`).Scan(&ok); err != nil {
		return fmt.Errorf("integrity_check: %w", err)
	}
	if ok != "ok" {
		add("integrity_check: %s", ok)
	}

	if err := SearchCheck(ctx, d); err != nil {
		add("%v", err)
	}

	var counts []string
	for _, t := range typeTables {
		counts = append(counts, fmt.Sprintf("(SELECT count(*) FROM %s x WHERE x.lesson_uuid = l.uuid)", t.table))
	}
	if err := eachRow(ctx, d, `SELECT l.uuid, l.type, `+strings.Join(counts, ", ")+` FROM lesson l`, func(r *sql.Rows) error {
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
		return fmt.Errorf("per-type rows: %w", err)
	}

	for _, q := range []struct{ sql, msg string }{
		{`SELECT q.lesson_uuid || ' question ' || q.position FROM quiz_question q
			WHERE (SELECT count(*) FROM quiz_answer a
				WHERE a.lesson_uuid = q.lesson_uuid AND a.question_position = q.position AND a.is_correct = 1) <> 1`,
			"quiz without exactly one right answer: %s"},
		{`SELECT s.lesson_uuid || ' step ' || s.position FROM cli_step s
			WHERE (s.kind = 'command' AND NOT EXISTS (SELECT 1 FROM cli_command c WHERE c.lesson_uuid = s.lesson_uuid AND c.step_position = s.position))
			   OR (s.kind = 'http' AND NOT EXISTS (SELECT 1 FROM cli_http_request h WHERE h.lesson_uuid = s.lesson_uuid AND h.step_position = s.position))`,
			"command-line step without its command or request: %s"},
	} {
		if err := eachRow(ctx, d, q.sql, func(r *sql.Rows) error {
			var what string
			if err := r.Scan(&what); err != nil {
				return err
			}
			add(q.msg, what)
			return nil
		}); err != nil {
			return err
		}
	}

	if len(problems) == 0 {
		return nil
	}
	if len(problems) > 25 {
		problems = append(problems[:25], fmt.Sprintf("and %d more", len(problems)-25))
	}
	return &CheckError{Problems: problems}
}

// CheckError lists what Check found wrong.
type CheckError struct{ Problems []string }

func (e *CheckError) Error() string {
	return "the database failed its checks:\n  " + strings.Join(e.Problems, "\n  ")
}

// SearchCheck runs the full-text index's own integrity check against the lesson table, in a
// transaction that is rolled back, so the file is not touched.
func SearchCheck(ctx context.Context, d *sql.DB) error {
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("search index check: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO lesson_search(lesson_search, rank) VALUES ('integrity-check', 1)`); err != nil {
		return fmt.Errorf("search index check: %w", err)
	}
	return nil
}

func eachRow(ctx context.Context, d *sql.DB, query string, fn func(*sql.Rows) error) error {
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
