// Command library makes, checks and migrates Gopherwood libraries: SQLite files in the format
// docs/library-format.md describes, whatever they hold and wherever it came from.
//
//	library create <file>   make a new, empty library
//	library check <file>    run the checks the app makes before it opens a library
//	library migrate <file>  bring a library of an older format up to date
//
// check prints one line for each problem and exits 1 if there is any. It writes nothing, with
// one exception: a write that was interrupted (a crash, or Ctrl-C during a sync) leaves a
// journal that has to be rolled back before the file can be read, and check does that first and
// says so, as SQLite itself would on any open that may write.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/jobloom/gopherwood/db"
)

const usage = `usage:
  library create <file>   make a new, empty library
  library check <file>    run the checks the app makes before it opens a library
  library migrate <file>  bring a library of an older format up to date`

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

// run carries out one command and returns the exit status: 0 for success, 1 for a library
// that fails or a command that could not be done, 2 for a usage mistake.
func run(ctx context.Context, args []string, out, errOut io.Writer) int {
	if len(args) != 2 {
		fmt.Fprintln(errOut, usage)
		return 2
	}
	var err error
	switch cmd, path := args[0], args[1]; cmd {
	case "create":
		err = create(path, out)
	case "check":
		var ok bool
		if ok, err = check(ctx, path, out); err == nil && !ok {
			return 1
		}
	case "migrate":
		err = migrate(ctx, path, out)
	default:
		fmt.Fprintf(errOut, "unknown command %q\n%s\n", cmd, usage)
		return 2
	}
	if err != nil {
		fmt.Fprintln(errOut, "library:", err)
		return 1
	}
	return 0
}

// create makes a new, empty library at path. Nothing may be there yet.
func create(path string, out io.Writer) error {
	d, err := db.Create(path)
	if err != nil {
		return err
	}
	if err := d.Close(); err != nil {
		return err
	}
	fmt.Fprintf(out, "created %s: an empty library of format %d\n", path, db.Version)
	return nil
}

// check runs the library checks on the file as it is, printing one line per problem, and
// reports whether it passed. It writes nothing.
func check(ctx context.Context, path string, out io.Writer) (bool, error) {
	d, recovered, err := db.Inspect(path)
	if err != nil {
		return false, err
	}
	defer d.Close()
	if recovered {
		fmt.Fprintln(out, db.RecoveredMessage(path))
	}
	problems, err := db.Validate(ctx, d)
	if err != nil {
		return false, err
	}
	for _, p := range problems {
		fmt.Fprintln(out, p)
	}
	if len(problems) > 0 {
		return false, nil
	}
	var courses, chapters, lessons int
	if err := d.QueryRowContext(ctx, `SELECT (SELECT count(*) FROM course), (SELECT count(*) FROM chapter), (SELECT count(*) FROM lesson)`).
		Scan(&courses, &chapters, &lessons); err != nil {
		return false, err
	}
	fmt.Fprintf(out, "ok: %s is a library of format %d with %d courses, %d chapters and %d lessons\n", path, db.Version, courses, chapters, lessons)
	return true, nil
}

// migrate brings a library of an older format up to date through the db package's migrations,
// then checks it. A library of a newer format, or a file that is not a library, is refused and
// left as it is.
func migrate(ctx context.Context, path string, out io.Writer) error {
	d, recovered, err := db.Inspect(path)
	if err != nil {
		return err
	}
	if recovered {
		fmt.Fprintln(out, db.RecoveredMessage(path))
	}
	var app, from int
	err = d.QueryRowContext(ctx, `SELECT (SELECT application_id FROM pragma_application_id), (SELECT user_version FROM pragma_user_version)`).Scan(&app, &from)
	d.Close()
	switch {
	case err != nil:
		return fmt.Errorf("%s: %w", path, err)
	case app != db.ApplicationID:
		return fmt.Errorf("%s is not a Gopherwood library (application_id %d)", path, app)
	case from > db.Version:
		return fmt.Errorf("%s is of format %d, newer than this program's %d; nothing changed", path, from, db.Version)
	case from == db.Version:
		fmt.Fprintf(out, "%s is already of format %d\n", path, from)
		return nil
	}
	d, err = db.Open(path) // migrates, one version at a time, each in one transaction
	if err != nil {
		return err
	}
	if err := d.Close(); err != nil {
		return err
	}
	fmt.Fprintf(out, "migrated %s from format %d to %d\n", path, from, db.Version)
	ok, err := check(ctx, path, out)
	if err == nil && !ok {
		err = errors.New("the migrated library fails its checks")
	}
	return err
}
