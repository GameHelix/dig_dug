package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"text/tabwriter"

	"github.com/jobloom/gopherwood/db"
	"github.com/jobloom/gopherwood/internal/bootdev"
	"github.com/jobloom/gopherwood/internal/lessons"
)

// runCheck runs the database's integrity checks and compares it with boot.dev: every course of
// the language with its lesson counts, and every course, chapter and lesson that is missing,
// changed, moved or no longer listed. It writes nothing, except that opening a database of an
// older schema migrates it (db.Open).
func runCheck(ctx context.Context, args []string, out io.Writer) error {
	fl := flag.NewFlagSet("check", flag.ContinueOnError)
	cf := addCommon(fl)
	quick := fl.Bool("quick", false, "do not load lesson pages: list the lessons that may have changed instead of comparing them")
	all := fl.Bool("all", false, "load and compare every lesson, not only those of courses that changed since they were saved")
	offline := fl.Bool("offline", false, "only check the database, without reading boot.dev")
	if err := parse(fl, args, out, "sync check [flags]"); err != nil {
		return err
	}
	path, err := cf.path()
	if err != nil {
		return err
	}
	d, err := db.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	fmt.Fprintf(out, "database %s\n", path)

	var failed []error
	problems, err := db.Validate(ctx, d)
	if err != nil {
		return err
	}
	if len(problems) > 0 {
		failed = append(failed, problems.Err())
		fmt.Fprintln(out, problems.Err())
	} else {
		fmt.Fprintln(out, "library checks (docs/library-format.md): application_id, user_version, quick_check, foreign keys, per-type rows, quiz answers and command-line steps all ok")
	}
	if err := db.SearchCheck(ctx, d); err != nil {
		failed = append(failed, err)
		fmt.Fprintln(out, err)
	} else {
		fmt.Fprintln(out, "search index: in step with the lessons")
	}
	left, err := lessons.MediaLeft(d)
	if err != nil {
		return err
	}
	if len(left) > 0 {
		failed = append(failed, fmt.Errorf("pictures, videos or widgets left in %s", strings.Join(left, ", ")))
		fmt.Fprintln(out, failed[len(failed)-1])
	} else {
		fmt.Fprintln(out, "pictures, videos and widgets: none in any readme, question, answer, step, prompt or description")
	}
	asking, err := askingLessons(d)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "command-line lessons that ask for the address of your own server (asks_for_base_url): %d\n", len(asking))
	for _, a := range asking {
		fmt.Fprintf(out, "  %s\n", a)
	}
	if err := printTotals(out, d, path); err != nil {
		return err
	}
	if *offline {
		return errors.Join(failed...)
	}

	c, err := cf.client(out)
	if err != nil {
		return err
	}
	gaps, err := compare(ctx, d, c, cf, *quick, *all, out)
	if err != nil {
		return err
	}
	if gaps > 0 {
		fmt.Fprintf(out, "\n%d differences from boot.dev; `sync` writes them\n", gaps)
	} else {
		fmt.Fprintln(out, "\nthe database holds everything boot.dev lists for these courses")
	}
	return errors.Join(failed...)
}

// compare prints the gap report and returns how many differences it found.
func compare(ctx context.Context, d *sql.DB, c *bootdev.Client, cf *common, quick, all bool, out io.Writer) (int, error) {
	catalog, err := c.Catalog(ctx)
	if err != nil {
		return 0, fmt.Errorf("the catalog: %w", err)
	}
	courses, unknown := goCourses(catalog, cf.lang)
	stored, err := lessons.LoadAll(d)
	if err != nil {
		return 0, err
	}
	stale, err := lessons.Unstripped(d)
	if err != nil {
		return 0, err
	}
	dbCourses, err := lessons.Courses(d)
	if err != nil {
		return 0, err
	}
	dbChapters, err := lessons.Chapters(d, "")
	if err != nil {
		return 0, err
	}
	haveCourse := map[string]bool{}
	for _, dc := range dbCourses {
		haveCourse[dc.UUID] = true
	}
	haveChapter := map[string]bool{}
	for _, ch := range dbChapters {
		haveChapter[ch.UUID] = true
	}

	fmt.Fprintf(out, "\nboot.dev's %s courses against the database:\n\n", cf.lang)
	tw := tabwriter.NewWriter(out, 2, 4, 2, ' ', tabwriter.AlignRight)
	fmt.Fprintln(tw, "course\tkind\tboot.dev\tdatabase\tmissing\tchanged\tmoved\tgone\t")
	var missing, changed, maybe, moved, gone, chapters, problems []string
	totals := [6]int{}
	only := cf.only()
	listedCourse := map[string]bool{}
	for _, cc := range courses {
		listedCourse[cc.UUID] = true
		if len(only) > 0 && !only[cc.Slug] {
			continue
		}
		if !haveCourse[cc.UUID] {
			chapters = append(chapters, "course "+cc.Slug+" ("+cc.Kind+")")
		}
		o, err := loadOutline(ctx, c, cc)
		if err != nil {
			if ctx.Err() != nil {
				return 0, ctx.Err()
			}
			problems = append(problems, err.Error())
			fmt.Fprintf(tw, "%s\t%s\t?\t%d\t\t\t\t\t\n", cc.Slug, cc.Kind, countIn(stored, cc.UUID))
			continue
		}
		for _, ch := range o.chapters {
			if !haveChapter[ch.UUID] {
				chapters = append(chapters, "chapter "+cc.Slug+" › "+ch.Title)
			}
		}
		n := [6]int{len(o.lessons), countIn(stored, cc.UUID)}
		for _, l := range o.lessons {
			s, have := stored[l.UUID]
			if !have {
				missing = append(missing, o.where[l.UUID])
				n[2]++
				continue
			}
			if p := o.places[l.UUID]; s.ChapterUUID != p.ChapterUUID || s.Position != p.Position || s.Required != p.Required {
				moved = append(moved, o.where[l.UUID])
				n[4]++
			}
			why := due(l, s, have, cc, all, stale[l.UUID])
			if why == "" {
				continue
			}
			if quick {
				maybe = append(maybe, o.where[l.UUID]+" ("+why+")")
				n[3]++
				continue
			}
			diff, err := lessonChanges(ctx, d, c, o, l.UUID)
			if err != nil {
				if ctx.Err() != nil {
					return 0, ctx.Err()
				}
				problems = append(problems, fmt.Sprintf("%s: %v", o.where[l.UUID], err))
				continue
			}
			if len(diff) > 0 {
				changed = append(changed, o.where[l.UUID]+": "+strings.Join(diff, ", "))
				n[3]++
			}
		}
		for u, s := range stored {
			if _, listed := o.places[u]; s.CourseUUID == cc.UUID && !listed {
				gone = append(gone, cc.Slug+" › "+s.Title+" ("+u+")")
				n[5]++
			}
		}
		for i := range n {
			totals[i] += n[i]
		}
		fmt.Fprintf(tw, "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t\n", cc.Slug, cc.Kind, n[0], n[1], n[2], n[3], n[4], n[5])
	}
	fmt.Fprintf(tw, "total\t\t%d\t%d\t%d\t%d\t%d\t%d\t\n", totals[0], totals[1], totals[2], totals[3], totals[4], totals[5])
	tw.Flush()

	for _, dc := range dbCourses {
		if !listedCourse[dc.UUID] {
			gone = append(gone, "course "+dc.Slug+" (boot.dev no longer lists it)")
		}
	}
	slices.Sort(gone)
	for _, l := range []struct {
		title string
		items []string
	}{
		{"courses and chapters the database lacks", chapters},
		{"lessons the database lacks", missing},
		{"lessons that changed on boot.dev", changed},
		{"lessons that may have changed (not loaded: -quick)", maybe},
		{"lessons in another place on boot.dev", moved},
		{"in the database, no longer on boot.dev (kept: lessons are never deleted)", gone},
		{"could not be checked", problems},
	} {
		if len(l.items) > 0 {
			fmt.Fprintf(out, "\n%s:\n  %s\n", l.title, strings.Join(l.items, "\n  "))
		}
	}
	otherMaterial(out, catalog, cf.lang, unknown)
	return len(chapters) + len(missing) + len(changed) + len(maybe) + len(moved) + len(gone) + len(problems), nil
}

// askingLessons lists the command-line lessons that need the address of your own server, such
// as an app you deployed, instead of suggesting one.
func askingLessons(d *sql.DB) ([]string, error) {
	rows, err := d.Query(`SELECT co.slug || ' › ' || ch.title || ' › ' || l.title FROM cli_lesson c
		JOIN lesson l ON l.uuid = c.lesson_uuid JOIN chapter ch ON ch.uuid = l.chapter_uuid JOIN course co ON co.uuid = ch.course_uuid
		WHERE c.asks_for_base_url = 1 ORDER BY co.position, ch.position, l.position`)
	if err != nil {
		return nil, fmt.Errorf("reading cli_lesson: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func countIn(stored map[string]lessons.Stored, course string) int {
	n := 0
	for _, s := range stored {
		if s.CourseUUID == course {
			n++
		}
	}
	return n
}

// lessonChanges loads a lesson and names what differs from the database's copy, its place
// aside.
func lessonChanges(ctx context.Context, d *sql.DB, c *bootdev.Client, o *outline, uuid string) ([]string, error) {
	rec, err := fetchLesson(ctx, c, o, uuid)
	if err != nil {
		return nil, err
	}
	cur, ok, err := lessons.Get(d, uuid)
	if err != nil || !ok {
		return nil, errors.Join(err, errors.New("not in the database"))
	}
	var diff []string
	for _, f := range lessons.LessonDiff(cur, rec.Lesson) {
		if f != "chapter" && f != "position" && f != "required" {
			diff = append(diff, f)
		}
	}
	parts, err := lessons.ReadParts(d, uuid)
	if err != nil {
		return nil, err
	}
	return append(diff, lessons.PartsDiff(parts, rec.Rows)...), nil
}

// otherMaterial reports what else the catalog has that touches the language, and why it is
// or is not synced.
func otherMaterial(out io.Writer, catalog []bootdev.Course, lang string, unknown []bootdev.Course) {
	byLang := map[string]map[string]int{}
	for _, c := range catalog {
		if byLang[c.Language] == nil {
			byLang[c.Language] = map[string]int{}
		}
		byLang[c.Language][c.Kind]++
	}
	var langs []string
	for _, l := range sortedKeys(byLang) {
		var kinds []string
		for _, k := range sortedKeys(byLang[l]) {
			kinds = append(kinds, fmt.Sprintf("%d %s", byLang[l][k], k))
		}
		langs = append(langs, l+": "+strings.Join(kinds, ", "))
	}
	fmt.Fprintf(out, "\nthe catalog's %d entries by language:\n  %s\n", len(catalog), strings.Join(langs, "\n  "))

	listed := map[string]bool{}
	for _, c := range catalog {
		if c.Language == lang {
			listed[c.Slug] = true
		}
	}
	var alternatives, agnostic, mentions []string
	for _, c := range catalog {
		if c.Language == lang {
			continue
		}
		if alt, ok := c.Alternatives[lang]; ok {
			state := "among the " + lang + " courses"
			if !listed[alt] {
				state = "NOT in the catalog's " + lang + " courses"
			}
			alternatives = append(alternatives, fmt.Sprintf("%s names %s as its %s version: %s", c.Slug, alt, lang, state))
		}
		if c.Language == "any" {
			agnostic = append(agnostic, fmt.Sprintf("%s (%s, %d lessons)", c.Slug, c.Kind, c.NumLessons))
		}
		for _, t := range c.Technologies {
			if t == lang || strings.EqualFold(t, map[string]string{"go": "golang"}[lang]) {
				mentions = append(mentions, c.Slug+" ("+c.Language+")")
				break
			}
		}
	}
	fmt.Fprintf(out, "\n%s material outside the %s courses:\n", lang, lang)
	if len(alternatives) > 0 {
		fmt.Fprintf(out, "  other-language courses that name a %s version:\n    %s\n", lang, strings.Join(alternatives, "\n    "))
	}
	if len(agnostic) > 0 {
		fmt.Fprintf(out, "  language-agnostic entries (language \"any\"), not %s-specific, not synced:\n    %s\n", lang, strings.Join(agnostic, "\n    "))
	}
	if len(mentions) > 0 {
		fmt.Fprintf(out, "  other-language courses that list %s among their technologies:\n    %s\n", lang, strings.Join(mentions, "\n    "))
	} else {
		fmt.Fprintf(out, "  no course of another language lists %s among its technologies or keywords\n", lang)
	}
	for _, u := range unknown {
		fmt.Fprintf(out, "  %s is a %s course of a kind the database does not hold: %q\n", u.Slug, lang, u.Kind)
	}
	fmt.Fprintf(out, "  synced: every entry whose language is %s, of both kinds boot.dev uses for them (Course and Guided Project)\n", lang)
}

// printTotals prints the rows of every table and the size of the file.
func printTotals(out io.Writer, d *sql.DB, path string) error {
	rows, err := d.Query(`SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'lesson_search%' ORDER BY rowid`)
	if err != nil {
		return err
	}
	var tables []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			rows.Close()
			return err
		}
		tables = append(tables, t)
	}
	rows.Close()
	fmt.Fprintln(out, "rows per table:")
	tw := tabwriter.NewWriter(out, 2, 4, 2, ' ', tabwriter.AlignRight)
	for _, t := range tables {
		var n int
		if err := d.QueryRow(`SELECT count(*) FROM ` + t).Scan(&n); err != nil {
			return err
		}
		fmt.Fprintf(tw, "  %s\t%d\t\n", t, n)
	}
	tw.Flush()
	if info, err := os.Stat(path); err == nil {
		fmt.Fprintf(out, "file size: %d bytes (%.1f MB)\n", info.Size(), float64(info.Size())/(1<<20))
	}
	return nil
}
