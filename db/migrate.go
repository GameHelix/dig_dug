package db

// Migrations take an older database to the schema this program knows, one version at a time,
// each in one transaction. A changed table always ends up with the definition schema.sql has
// for it: the migration creates it from that text and copies the rows over.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// migrations[v] takes a database of schema version v to version v+1, in the transaction it is
// given, with foreign keys off.
var migrations = map[int]func(ctx context.Context, tx *sql.Tx) error{
	3: migrate3to4,
	4: migrate4to5,
	5: migrate5to6,
}

// migrate3to4 makes version 4:
//   - cli_lesson.base_url_default holds only real addresses. The source's 'override', which
//     means the lesson needs the address of your own server, becomes asks_for_base_url = 1.
//   - project.dir may be NULL, so a course can have an address without a folder.
//   - server_address is new.
func migrate3to4(ctx context.Context, tx *sql.Tx) error {
	if err := rebuild(ctx, tx, "cli_lesson", `
		INSERT INTO new_cli_lesson (lesson_uuid, lesson_type, base_url_default, asks_for_base_url, use_agent_prompt, contains_complete_dir)
		SELECT lesson_uuid, lesson_type, nullif(base_url_default, 'override'), base_url_default IS 'override',
		       use_agent_prompt, contains_complete_dir
		FROM cli_lesson`); err != nil {
		return err
	}
	if err := rebuild(ctx, tx, "project", `
		INSERT INTO new_project (course_uuid, dir, base_url) SELECT course_uuid, dir, base_url FROM project`); err != nil {
		return err
	}
	create, err := tableDefinition("server_address")
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, create); err != nil {
		return fmt.Errorf("server_address: %w", err)
	}
	return nil
}

// migrate4to5 makes version 5: interview_lesson.acceptance_criteria is NULL where the lesson
// gives none, instead of an empty or blank string. Every other value is copied exactly.
func migrate4to5(ctx context.Context, tx *sql.Tx) error {
	return rebuild(ctx, tx, "interview_lesson", `
		INSERT INTO new_interview_lesson (lesson_uuid, lesson_type, student_prompt, acceptance_criteria)
		SELECT lesson_uuid, lesson_type, student_prompt,
		       CASE WHEN trim(acceptance_criteria, ' ' || char(9, 10, 11, 12, 13)) = '' THEN NULL ELSE acceptance_criteria END
		FROM interview_lesson`)
}

// migrate5to6 makes version 6: solution_file, the reference solutions producers verify their
// lessons with, is new.
func migrate5to6(ctx context.Context, tx *sql.Tx) error {
	create, err := tableDefinition("solution_file")
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, create); err != nil {
		return fmt.Errorf("solution_file: %w", err)
	}
	return nil
}

// migrate runs the migration from version from in one transaction, on one connection, with
// foreign keys off while it runs and foreign_key_check before it commits: steps 1, 2, 10, 11
// and 12 of SQLite's procedure for schema changes ALTER TABLE cannot make
// (https://www.sqlite.org/lang_altertable.html#otheralter). rebuild does the steps between.
func migrate(ctx context.Context, d *sql.DB, from int) (err error) {
	m := migrations[from]
	if m == nil {
		return fmt.Errorf("no migration from schema version %d", from)
	}
	conn, err := d.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	// Outside a transaction, where the pragma takes effect.
	if _, err := conn.ExecContext(ctx, `PRAGMA foreign_keys = OFF`); err != nil {
		return err
	}
	defer func() {
		if _, on := conn.ExecContext(context.Background(), `PRAGMA foreign_keys = ON`); on != nil {
			err = errors.Join(err, fmt.Errorf("turning foreign keys back on: %w", on))
		}
	}()
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := m(ctx, tx); err != nil {
		return fmt.Errorf("migrating from version %d: %w", from, err)
	}
	var broken []string
	rows, err := tx.QueryContext(ctx, `SELECT "table", rowid, parent FROM pragma_foreign_key_check`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var table, parent string
		var rowid sql.NullInt64
		if err := rows.Scan(&table, &rowid, &parent); err != nil {
			rows.Close()
			return err
		}
		broken = append(broken, fmt.Sprintf("%s row %d points at a missing %s row", table, rowid.Int64, parent))
	}
	rows.Close()
	if len(broken) > 0 {
		return fmt.Errorf("migrating from version %d would leave foreign keys pointing nowhere, so nothing changed:\n  %s", from, strings.Join(broken, "\n  "))
	}
	if _, err := tx.ExecContext(ctx, fmt.Sprintf(`PRAGMA user_version = %d`, from+1)); err != nil {
		return err
	}
	return tx.Commit()
}

// rebuild gives table the definition schema.sql has for it, by steps 3 to 8 of SQLite's
// procedure: remember the table's indexes and triggers, create the new table as new_<table>,
// copy the rows with copyRows, drop the old table, rename the new one to its name, and make
// the indexes and triggers again. Foreign keys must be off, so that dropping the table does
// not delete the rows that hang from it; migrate sees to that.
func rebuild(ctx context.Context, tx *sql.Tx, table, copyRows string) error {
	create, err := tableDefinition(table)
	if err != nil {
		return err
	}
	head := "CREATE TABLE " + table + " ("
	tmp := "new_" + table
	var keep []string
	rows, err := tx.QueryContext(ctx, `SELECT sql FROM sqlite_schema WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL`, table)
	if err != nil {
		return err
	}
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			rows.Close()
			return err
		}
		keep = append(keep, s)
	}
	rows.Close()
	steps := append([]string{
		"CREATE TABLE " + tmp + " (" + strings.TrimPrefix(create, head),
		copyRows,
		"DROP TABLE " + table,
		"ALTER TABLE " + tmp + " RENAME TO " + table,
	}, keep...)
	for _, s := range steps {
		if _, err := tx.ExecContext(ctx, s); err != nil {
			return fmt.Errorf("rebuilding %s: %w", table, err)
		}
	}
	return nil
}

// tableDefinition returns schema.sql's CREATE TABLE statement for a table.
func tableDefinition(table string) (string, error) {
	head := "CREATE TABLE " + table + " ("
	for _, s := range statements(Schema) {
		if body := withoutLeadingComments(s); strings.HasPrefix(body, head) {
			return body, nil
		}
	}
	return "", fmt.Errorf("schema.sql defines no table %s", table)
}

// statements splits SQL text at the semicolons outside comments and quotes. A trigger's body
// is split too, which is fine for finding CREATE TABLE statements.
func statements(text string) []string {
	var out []string
	var b strings.Builder
	var quote byte
	comment := false
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case comment:
			comment = c != '\n'
		case quote != 0:
			if c == quote {
				quote = 0
			}
		case c == '-' && i+1 < len(text) && text[i+1] == '-':
			comment = true
		case c == '\'' || c == '"':
			quote = c
		case c == ';':
			out = append(out, b.String())
			b.Reset()
			continue
		}
		b.WriteByte(c)
	}
	if strings.TrimSpace(b.String()) != "" {
		out = append(out, b.String())
	}
	return out
}

// withoutLeadingComments drops the blank and comment lines before a statement.
func withoutLeadingComments(s string) string {
	for {
		s = strings.TrimLeft(s, " \t\r\n")
		if !strings.HasPrefix(s, "--") {
			return s
		}
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			return ""
		}
		s = s[i+1:]
	}
}
