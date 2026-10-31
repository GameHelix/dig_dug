package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/jobloom/gopherwood/db"
	"github.com/jobloom/gopherwood/internal/bootdev"
	"github.com/jobloom/gopherwood/internal/lessons"
)

// syncReport is what a sync did.
type syncReport struct {
	courses, chapters lessons.Counts
	added, changed    []string
	confirmed         int // loaded again and found the same
	current           int // known current without loading
	moved, gone       []string
	failed            []string
	deferred          int
	media             int // pictures, videos and video links removed from the lessons written
}

// runSync fetches the courses of a language from boot.dev and writes what changed: new
// courses, chapters and lessons, lessons whose content changed, and their order. A lesson is
// loaded again only when its course changed on boot.dev after the lesson was saved.
func runSync(ctx context.Context, args []string, out io.Writer) error {
	fl := flag.NewFlagSet("sync", flag.ContinueOnError)
	cf := addCommon(fl)
	all := fl.Bool("all", false, "load every lesson again, not only those of courses that changed since they were saved")
	limit := fl.Int("limit", 0, "load at most this many lessons (0: no limit); run again for the rest")
	if err := parse(fl, args, out, "sync [flags]"); err != nil {
		return err
	}
	path, err := cf.path()
	if err != nil {
		return err
	}
	d, created, err := openOrCreate(path)
	if err != nil {
		return err
	}
	defer d.Close()
	c, err := cf.client(out)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "database %s\n", path)

	catalog, err := c.Catalog(ctx)
	if err != nil {
		return fmt.Errorf("the catalog: %w", err)
	}
	courses, unknown := goCourses(catalog, cf.lang)
	if len(courses) == 0 {
		return fmt.Errorf("boot.dev lists no %q courses among %d", cf.lang, len(catalog))
	}
	fmt.Fprintf(out, "boot.dev lists %d %s courses\n", len(courses), cf.lang)
	for _, u := range unknown {
		fmt.Fprintf(out, "  left out: %s, a %q, a kind the database does not hold\n", u.Slug, u.Kind)
	}

	var rep syncReport
	var want []lessons.Course
	for _, cc := range courses {
		want = append(want, courseRow(cc))
	}
	if err := inTx(d, func(tx *sql.Tx) (err error) {
		rep.courses, err = lessons.PlaceCourses(tx, want)
		return err
	}); err != nil {
		return err
	}
	stored, err := lessons.LoadAll(d)
	if err != nil {
		return err
	}
	stale, err := lessons.Unstripped(d)
	if err != nil {
		return err
	}

	only := cf.only()
	budget := *limit
	for _, cc := range courses {
		if len(only) > 0 && !only[cc.Slug] {
			continue
		}
		if err := syncCourse(ctx, d, c, cc, stored, stale, *all, &budget, *limit > 0, &rep, out); err != nil {
			if ctx.Err() != nil {
				return fmt.Errorf("stopped: %w; run again to go on", ctx.Err())
			}
			rep.failed = append(rep.failed, err.Error())
			fmt.Fprintf(out, "  ! %v\n", err)
		}
	}

	if err := db.Check(ctx, d); err != nil {
		return err
	}
	if left, err := lessons.MediaLeft(d); err != nil {
		return err
	} else if len(left) > 0 {
		return fmt.Errorf("pictures, videos or widgets left in %s", strings.Join(left, ", "))
	}
	if created {
		// A new database is a full rebuild: compact it once. lesson.id survives VACUUM.
		if err := vacuum(ctx, d); err != nil {
			return err
		}
	}
	rep.print(out, c.Loads())
	if err := printTotals(out, d, path); err != nil {
		return err
	}
	if len(rep.failed) > 0 {
		return fmt.Errorf("%d lessons or courses could not be synced; run again to retry them", len(rep.failed))
	}
	return nil
}

func syncCourse(ctx context.Context, d *sql.DB, c *bootdev.Client, cc bootdev.Course, stored map[string]lessons.Stored,
	stale map[string]bool, all bool, budget *int, limited bool, rep *syncReport, out io.Writer) error {
	o, err := loadOutline(ctx, c, cc)
	if err != nil {
		return err
	}
	var moved, gone []string
	if err := inTx(d, func(tx *sql.Tx) error {
		n, err := lessons.PlaceChapters(tx, cc.UUID, o.chapters)
		if err != nil {
			return err
		}
		for i := range n {
			rep.chapters[i] += n[i]
		}
		moved, gone, err = lessons.PlaceLessons(tx, cc.UUID, o.places)
		return err
	}); err != nil {
		return fmt.Errorf("%s: %w", cc.Slug, err)
	}
	for _, u := range moved {
		if _, listed := o.places[u]; listed {
			rep.moved = append(rep.moved, o.where[u])
		}
	}
	for _, u := range gone {
		rep.gone = append(rep.gone, cc.Slug+" › "+stored[u].Title+" ("+u+")")
	}
	renamable := func(u string) bool { return slices.Contains(gone, u) }

	var todo []string
	reasons := map[string]string{}
	for _, l := range o.lessons {
		s, have := stored[l.UUID]
		if why := due(l, s, have, cc, all, stale[l.UUID]); why != "" {
			todo = append(todo, l.UUID)
			reasons[l.UUID] = why
		} else {
			rep.current++
		}
	}
	fmt.Fprintf(out, "%s (%s): %d chapters, %d lessons; %s\n", cc.Slug, cc.Kind, len(o.chapters), len(o.lessons), summary(todo, reasons, cc))
	for _, u := range todo {
		if limited && *budget <= 0 {
			rep.deferred++
			continue
		}
		*budget--
		rec, err := fetchLesson(ctx, c, o, u)
		if err != nil {
			if ctx.Err() != nil {
				return err
			}
			rep.failed = append(rep.failed, fmt.Sprintf("%s: %v", o.where[u], err))
			fmt.Fprintf(out, "  ! %s: %v\n", o.where[u], err)
			continue
		}
		var ch lessons.Change
		var diff []string
		if err := inTx(d, func(tx *sql.Tx) error {
			var err error
			if ch, diff, err = lessons.Put(tx, rec, renamable); err != nil {
				return err
			}
			if ch == lessons.Same {
				return lessons.Touch(tx, u, rec.Lesson.SyncedAt)
			}
			return nil
		}); err != nil {
			rep.failed = append(rep.failed, fmt.Sprintf("%s: %v", o.where[u], err))
			fmt.Fprintf(out, "  ! %s: %v\n", o.where[u], err)
			continue
		}
		switch ch {
		case lessons.Added:
			rep.media += rec.Media.Total()
			rep.added = append(rep.added, o.where[u])
			fmt.Fprintf(out, "  + %s\n", o.where[u])
		case lessons.Changed:
			rep.media += rec.Media.Total()
			rep.changed = append(rep.changed, o.where[u]+": "+strings.Join(diff, ", "))
			fmt.Fprintf(out, "  ~ %s: %s\n", o.where[u], strings.Join(diff, ", "))
		default:
			rep.confirmed++
		}
	}
	return nil
}

func summary(todo []string, reasons map[string]string, cc bootdev.Course) string {
	if len(todo) == 0 {
		return "up to date (it last changed on boot.dev " + cc.LastUpdated.Format("2006-01-02 15:04 UTC") + ")"
	}
	count := map[string]int{}
	for _, u := range todo {
		count[reasons[u]]++
	}
	var parts []string
	for _, why := range sortedKeys(count) {
		parts = append(parts, fmt.Sprintf("%d %s", count[why], why))
	}
	return "loading " + strings.Join(parts, ", ")
}

func (r *syncReport) print(out io.Writer, loads int) {
	fmt.Fprintln(out)
	fmt.Fprintf(out, "courses   %d added, %d changed, %d unchanged\n", r.courses[lessons.Added], r.courses[lessons.Changed], r.courses[lessons.Same])
	fmt.Fprintf(out, "chapters  %d added, %d changed, %d unchanged\n", r.chapters[lessons.Added], r.chapters[lessons.Changed], r.chapters[lessons.Same])
	fmt.Fprintf(out, "lessons   %d added, %d changed, %d loaded again and unchanged, %d known current, %d moved\n",
		len(r.added), len(r.changed), r.confirmed, r.current, len(r.moved))
	if r.media > 0 {
		fmt.Fprintf(out, "removed %d pictures, videos, video links and widgets from the new and changed lessons\n", r.media)
	}
	if len(r.gone) > 0 {
		fmt.Fprintf(out, "no longer on boot.dev, kept in the database: %s\n", strings.Join(r.gone, "; "))
	}
	if r.deferred > 0 {
		fmt.Fprintf(out, "%d lessons left for the next run (-limit)\n", r.deferred)
	}
	if len(r.failed) > 0 {
		fmt.Fprintf(out, "could not be synced:\n  %s\n", strings.Join(r.failed, "\n  "))
	}
	fmt.Fprintf(out, "%d pages loaded from boot.dev\n\n", loads)
}

// inTx runs fn in a transaction and commits it.
func inTx(d *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := d.Begin()
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		return errors.Join(err, tx.Rollback())
	}
	return tx.Commit()
}

func vacuum(ctx context.Context, d *sql.DB) error {
	if _, err := d.ExecContext(ctx, `VACUUM`); err != nil {
		return fmt.Errorf("VACUUM: %w", err)
	}
	return db.SearchCheck(ctx, d)
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}
