// Command sync keeps the lessons in data/gopherwood.sqlite in step with boot.dev's Go
// courses, a personal copy for offline study.
//
//	sync [flags]        fetch boot.dev's Go courses and write what changed (the default)
//	sync check [flags]  check the database and compare it with boot.dev, writing nothing
//
// It reads boot.dev's public pages one at a time, 2 to 4 seconds apart, and never downloads a
// picture or a video. A run can be stopped at any time and started again.
package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jobloom/gopherwood/db"
	"github.com/jobloom/gopherwood/internal/bootdev"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout); err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			fmt.Fprintln(os.Stderr, "sync:", err)
		}
		os.Exit(1)
	}
}

const usage = `usage:
  sync [flags]        fetch boot.dev's Go courses and write what changed
  sync check [flags]  check the database and compare it with boot.dev

Run "sync <command> -h" for a command's flags.`

func run(ctx context.Context, args []string, out io.Writer) error {
	cmd := "sync"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "sync":
		return runSync(ctx, args, out)
	case "check":
		return runCheck(ctx, args, out)
	case "help":
		fmt.Fprintln(out, usage)
		return nil
	}
	return fmt.Errorf("unknown command %q\n%s", cmd, usage)
}

// common holds the flags every command shares.
type common struct {
	db      string
	lang    string
	courses string
	site    string
	delay   time.Duration
}

func addCommon(fl *flag.FlagSet) *common {
	c := &common{}
	fl.StringVar(&c.db, "db", "", "the database `file` (default: data/gopherwood.sqlite in this repository)")
	fl.StringVar(&c.lang, "lang", "go", "the `language` whose courses to sync")
	fl.StringVar(&c.courses, "courses", "", "only these course `slugs`, comma-separated (default: every course of the language)")
	fl.StringVar(&c.site, "site", bootdev.BaseURL, "the `site` to read; boot.dev is always read 2 to 4 s per page")
	fl.DurationVar(&c.delay, "delay", bootdev.MinDelay, "the shortest `pause` between page loads; up to as much again is added at random")
	return c
}

func (c *common) path() (string, error) {
	if c.db != "" {
		return c.db, nil
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return db.Path(wd)
}

func (c *common) only() map[string]bool {
	m := map[string]bool{}
	for s := range strings.SplitSeq(c.courses, ",") {
		if s = strings.TrimSpace(s); s != "" {
			m[s] = true
		}
	}
	return m
}

func (c *common) client(out io.Writer) (*bootdev.Client, error) {
	return bootdev.New(
		bootdev.WithBaseURL(c.site),
		bootdev.WithDelay(c.delay),
		bootdev.WithLogger(func(format string, args ...any) { fmt.Fprintf(out, "  "+format+"\n", args...) }),
	)
}

// openOrCreate opens the database at path, or makes it from schema.sql if there is none yet.
func openOrCreate(path string) (d *sql.DB, created bool, err error) {
	d, err = db.Open(path)
	if errors.Is(err, db.ErrNotFound) {
		d, err = db.Create(path)
		return d, err == nil, err
	}
	return d, false, err
}

// parse parses a command's flags, printing its usage on -h.
func parse(fl *flag.FlagSet, args []string, out io.Writer, synopsis string) error {
	fl.SetOutput(out)
	fl.Usage = func() {
		fmt.Fprintln(out, "usage: "+synopsis)
		fl.PrintDefaults()
	}
	if err := fl.Parse(args); err != nil {
		return err
	}
	if fl.NArg() > 0 {
		fl.Usage()
		return fmt.Errorf("unexpected arguments: %s", strings.Join(fl.Args(), " "))
	}
	return nil
}
