package main

// verify runs every code lesson of a library with the Go toolchain, in a temporary folder:
// with its solution the lesson must pass, and with its starter it must not.

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/jobloom/gopherwood/db"
)

var (
	runTimeout   = 10 * time.Second // a run that takes longer is stopped and reported
	slowAfter    = 2 * time.Second  // a run that takes longer is reported as slow
	buildTimeout = 2 * time.Minute  // building is not a run: a cold build cache is slow
)

type codeLesson struct {
	uuid, name, typ string // name is course/chapter/lesson
	expected        sql.NullString
	starter         []starterFile
	solution        map[string]string
}

type starterFile struct {
	name, content    string
	hidden, readonly bool
}

func (f starterFile) editable() bool { return !f.hidden && !f.readonly }

// verify checks the code lessons of the library at path, of one course if course is set,
// printing one line per problem. It reports whether there were none.
func verify(ctx context.Context, path, course string, out io.Writer) (bool, error) {
	goBin, err := osexec.LookPath("go")
	if err != nil {
		return false, errors.New("verify runs lessons with the go command, which is not on PATH")
	}
	d, recovered, err := db.Inspect(path)
	if err != nil {
		return false, err
	}
	defer d.Close()
	if recovered {
		fmt.Fprintln(out, db.RecoveredMessage(path))
	}
	var version int
	if err := d.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&version); err != nil {
		return false, fmt.Errorf("%s: %w", path, err)
	}
	if version != db.Version {
		return false, fmt.Errorf("%s is of format %d, not %d; migrate it first", path, version, db.Version)
	}
	ls, err := loadCodeLessons(ctx, d, course)
	if err != nil {
		return false, err
	}
	problems := 0
	for _, l := range ls {
		for _, p := range verifyLesson(ctx, goBin, l) {
			fmt.Fprintf(out, "%s: %s\n", l.name, p)
			problems++
		}
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
	}
	if problems == 0 {
		fmt.Fprintf(out, "ok: %d code lessons of %s pass with their solutions and fail with their starters\n", len(ls), path)
	}
	return problems == 0, nil
}

func loadCodeLessons(ctx context.Context, d *sql.DB, course string) ([]*codeLesson, error) {
	query := `SELECT l.uuid, co.slug || '/' || ch.slug || '/' || l.slug, l.type, c.expected_output
		FROM lesson l JOIN code_lesson c ON c.lesson_uuid = l.uuid
		JOIN chapter ch ON ch.uuid = l.chapter_uuid JOIN course co ON co.uuid = ch.course_uuid`
	var args []any
	if course != "" {
		var n int
		if err := d.QueryRowContext(ctx, `SELECT count(*) FROM course WHERE slug = ?`, course).Scan(&n); err != nil || n == 0 {
			return nil, errors.Join(err, fmt.Errorf("the library has no course %s", course))
		}
		query += ` WHERE co.slug = ?`
		args = append(args, course)
	}
	rows, err := d.QueryContext(ctx, query+` ORDER BY co.position, ch.position, l.position`, args...)
	if err != nil {
		return nil, err
	}
	var ls []*codeLesson
	for rows.Next() {
		l := &codeLesson{solution: map[string]string{}}
		if err := rows.Scan(&l.uuid, &l.name, &l.typ, &l.expected); err != nil {
			rows.Close()
			return nil, err
		}
		ls = append(ls, l)
	}
	rows.Close()
	for _, l := range ls {
		files, err := d.QueryContext(ctx, `SELECT name, content, is_hidden, is_readonly FROM starter_file WHERE lesson_uuid = ? ORDER BY position`, l.uuid)
		if err != nil {
			return nil, err
		}
		for files.Next() {
			var f starterFile
			if err := files.Scan(&f.name, &f.content, &f.hidden, &f.readonly); err != nil {
				files.Close()
				return nil, err
			}
			l.starter = append(l.starter, f)
		}
		files.Close()
		sols, err := d.QueryContext(ctx, `SELECT name, content FROM solution_file WHERE lesson_uuid = ?`, l.uuid)
		if err != nil {
			return nil, err
		}
		for sols.Next() {
			var name, content string
			if err := sols.Scan(&name, &content); err != nil {
				sols.Close()
				return nil, err
			}
			l.solution[name] = content
		}
		sols.Close()
	}
	return ls, nil
}

// verifyLesson returns the problems of one code lesson.
func verifyLesson(ctx context.Context, goBin string, l *codeLesson) []string {
	var problems []string
	add := func(format string, args ...any) { problems = append(problems, fmt.Sprintf(format, args...)) }
	if len(l.solution) == 0 {
		add("has no solution files to verify it with")
		return problems
	}
	for _, f := range l.starter {
		if _, ok := l.solution[f.name]; f.editable() && !ok {
			add("has no solution for %s, a file the learner edits", f.name)
		}
	}
	tests := l.typ == "type_code_tests"
	if tests {
		problems = append(problems, testsThatCannotFail(l.starter)...)
	}
	for _, side := range []string{"solution", "starter"} {
		r, err := runLesson(ctx, goBin, l, side == "solution")
		if err != nil {
			add("could not be run with its %s: %v", side, err)
			continue
		}
		what := "the " + side
		if tests {
			what += "'s tests"
		}
		switch {
		case r.timedOut:
			add("%s did not finish within %s", what, runTimeout)
			continue
		case r.built && r.took > slowAfter:
			add("%s took %s to run, over %s", what, r.took.Round(10*time.Millisecond), slowAfter)
		}
		switch {
		case side == "solution" && !r.built && tests:
			add("the solution's tests do not build: %s", buildError(r.buildOutput))
		case side == "solution" && !r.built:
			add("the solution does not build: %s", buildError(r.buildOutput))
		case side == "solution" && tests && r.exit != 0:
			add("the solution fails its tests: %s", firstFailure(r.stdout+r.stderr))
		case side == "solution" && !tests && r.exit != 0:
			add("the solution exits with status %d: %s", r.exit, firstLine(r.stderr))
		case side == "solution" && !tests && r.stdout != l.expected.String:
			add("the solution prints %s, not the expected %s", clip(r.stdout), clip(l.expected.String))
		case side == "starter" && tests && r.built && r.exit == 0:
			add("the starter passes its tests: they should fail until the learner solves the lesson")
		case side == "starter" && !tests && r.built && r.exit == 0 && r.stdout == l.expected.String:
			add("the starter already prints the expected output")
		}
	}
	return problems
}

type result struct {
	built       bool
	buildOutput string
	exit        int
	stdout      string
	stderr      string
	took        time.Duration
	timedOut    bool
}

// runLesson builds the lesson with its solution or its starter in a temporary folder and runs
// it: the program for a code lesson, the compiled tests for a code_tests lesson.
func runLesson(ctx context.Context, goBin string, l *codeLesson, solved bool) (result, error) {
	var r result
	dir, err := os.MkdirTemp("", "gopherwood-verify-")
	if err != nil {
		return r, err
	}
	defer os.RemoveAll(dir)
	src := filepath.Join(dir, "lesson")
	hasMod := false
	for _, f := range l.starter {
		content := f.content
		if solved && f.editable() {
			if s, ok := l.solution[f.name]; ok {
				content = s
			}
		}
		if !filepath.IsLocal(filepath.FromSlash(f.name)) {
			return r, fmt.Errorf("starter file %q is not a path inside the lesson", f.name)
		}
		file := filepath.Join(src, filepath.FromSlash(f.name))
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			return r, err
		}
		if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
			return r, err
		}
		hasMod = hasMod || f.name == "go.mod"
	}
	if !hasMod {
		if err := os.WriteFile(filepath.Join(src, "go.mod"), []byte("module lesson\n\ngo 1.24\n"), 0o644); err != nil {
			return r, err
		}
	}
	env := append(os.Environ(), "GOTOOLCHAIN=local", "GOWORK=off", "GOPROXY=off", "GOFLAGS=", "CGO_ENABLED=0")
	bin := filepath.Join(dir, "lesson.bin")
	build := []string{"build", "-o", bin, "."}
	if l.typ == "type_code_tests" {
		build = []string{"test", "-c", "-o", bin, "."}
	}
	b := command(ctx, buildTimeout, src, env, goBin, build...)
	if b.timedOut {
		return r, fmt.Errorf("building took over %s", buildTimeout)
	}
	if b.exit != 0 || b.err != nil {
		r.buildOutput = strings.TrimSpace(b.stdout + b.stderr)
		if r.buildOutput == "" && b.err != nil {
			r.buildOutput = b.err.Error()
		}
		return r, nil
	}
	r.built = true
	args := []string{}
	if l.typ == "type_code_tests" {
		args = []string{"-test.count=1"}
	}
	c := command(ctx, runTimeout, src, os.Environ(), bin, args...)
	if c.err != nil && !c.timedOut {
		return r, c.err // it did not start
	}
	r.exit, r.stdout, r.stderr, r.took, r.timedOut = c.exit, c.stdout, c.stderr, c.took, c.timedOut
	return r, nil
}

type commandResult struct {
	exit           int
	stdout, stderr string
	took           time.Duration
	timedOut       bool
	err            error
}

// command runs a program in its own process group, which a timeout kills whole.
func command(ctx context.Context, timeout time.Duration, dir string, env []string, name string, args ...string) commandResult {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := osexec.CommandContext(ctx, name, args...)
	cmd.Dir, cmd.Env = dir, env
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &capped{buf: &stdout}, &capped{buf: &stderr}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	start := time.Now()
	err := cmd.Run()
	r := commandResult{stdout: stdout.String(), stderr: stderr.String(), took: time.Since(start), timedOut: errors.Is(ctx.Err(), context.DeadlineExceeded)}
	var exit *osexec.ExitError
	switch {
	case errors.As(err, &exit):
		r.exit = exit.ExitCode()
		if r.exit < 0 {
			r.exit = 1 // killed by a signal
		}
	case err != nil:
		r.exit, r.err = 1, err
	}
	return r
}

// capped keeps the first megabyte written to it and drops the rest.
type capped struct{ buf *bytes.Buffer }

func (c *capped) Write(p []byte) (int, error) {
	if room := 1<<20 - c.buf.Len(); room > 0 {
		c.buf.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

// testsThatCannotFail finds test files whose tests never fail: tests that only print PASS or
// FAIL pass whatever the learner writes.
func testsThatCannotFail(files []starterFile) []string {
	var problems []string
	for _, f := range files {
		if !strings.HasSuffix(f.name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(token.NewFileSet(), f.name, f.content, 0)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s does not parse: %v", f.name, err))
			continue
		}
		tests, fails := 0, false
		for _, decl := range file.Decls {
			if fn, ok := decl.(*ast.FuncDecl); ok && strings.HasPrefix(fn.Name.Name, "Test") && fn.Recv == nil {
				tests++
			}
		}
		ast.Inspect(file, func(n ast.Node) bool {
			if call, ok := n.(*ast.CallExpr); ok {
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
					switch sel.Sel.Name {
					case "Error", "Errorf", "Fatal", "Fatalf", "Fail", "FailNow":
						fails = true
					}
				}
			}
			return !fails
		})
		if tests > 0 && !fails {
			problems = append(problems, fmt.Sprintf("%s never fails a test: it calls no t.Error, t.Errorf, t.Fatal or t.Fatalf, so a test that only prints PASS or FAIL cannot fail", f.name))
		}
	}
	return problems
}

// buildError returns the first line of go build output that says what is wrong, past the
// "# package" header.
func buildError(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" && !strings.HasPrefix(t, "# ") {
			return clipText(t, 160)
		}
	}
	return firstLine(s)
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return clipText(s, 160)
}

// firstFailure returns the first line of go test output that says what failed.
func firstFailure(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" && !strings.HasPrefix(t, "=== ") && !strings.HasPrefix(t, "--- FAIL") && t != "FAIL" {
			return clipText(t, 160)
		}
	}
	return firstLine(s)
}

func clip(s string) string { return fmt.Sprintf("%q", clipText(s, 80)) }

func clipText(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}
