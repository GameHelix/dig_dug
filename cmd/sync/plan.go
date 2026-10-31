package main

import (
	"context"
	"fmt"
	"time"

	"github.com/jobloom/gopherwood/internal/bootdev"
	"github.com/jobloom/gopherwood/internal/lessons"
	"github.com/jobloom/gopherwood/internal/media"
)

// freshness allows for clocks that disagree: a lesson saved this long after its course last
// changed on boot.dev counts as current.
const freshness = 15 * time.Minute

// knownKinds are the kinds of course the database holds.
var knownKinds = map[string]bool{"Course": true, "Guided Project": true}

// goCourses returns the catalog entries of lang the database can hold, in catalog order, and
// those of another kind.
func goCourses(all []bootdev.Course, lang string) (courses, unknown []bootdev.Course) {
	for _, c := range bootdev.OfLanguage(all, lang) {
		if knownKinds[c.Kind] {
			courses = append(courses, c)
		} else {
			unknown = append(unknown, c)
		}
	}
	return courses, unknown
}

func courseRow(c bootdev.Course) lessons.Course {
	return lessons.Course{UUID: c.UUID, Slug: c.Slug, Title: c.Title, Kind: c.Kind,
		ShortDescription: prose(c.ShortDescription), Description: prose(c.Description)}
}

func prose(s string) string {
	out, _ := media.Strip(s)
	return out
}

// outline is a course as its first lesson's page lists it.
type outline struct {
	course   bootdev.Course
	page     map[string]any // the first lesson's page, which also holds that lesson
	chapters []lessons.Chapter
	places   map[string]lessons.Placement
	lessons  []bootdev.LessonRef // every listed lesson, in order
	where    map[string]string   // lesson uuid -> "course › chapter › title", for reports
}

func loadOutline(ctx context.Context, c *bootdev.Client, cc bootdev.Course) (*outline, error) {
	if cc.FirstLesson == "" {
		return nil, fmt.Errorf("%s: the catalog names no first lesson", cc.Slug)
	}
	page, err := c.LessonPage(ctx, cc.FirstLesson)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", cc.Slug, err)
	}
	chapters, err := bootdev.ParseOutline(page, cc.UUID)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", cc.Slug, err)
	}
	meta := map[string]bootdev.CatalogChapter{}
	for _, ch := range cc.Chapters {
		meta[ch.UUID] = ch
	}
	o := &outline{course: cc, page: page, places: map[string]lessons.Placement{}, where: map[string]string{}}
	for _, ch := range chapters {
		m := meta[ch.UUID]
		title := ch.Title
		if title == "" {
			title = m.Title
		}
		o.chapters = append(o.chapters, lessons.Chapter{UUID: ch.UUID, Slug: m.Slug, Title: title, Description: prose(m.Description)})
		for i, l := range ch.Lessons {
			o.places[l.UUID] = lessons.Placement{ChapterUUID: ch.UUID, Position: int64(i), Required: l.Required}
			o.lessons = append(o.lessons, l)
			o.where[l.UUID] = cc.Slug + " › " + title + " › " + l.Title
		}
	}
	return o, nil
}

// due says why a listed lesson has to be loaded again, or "" when the database is known to
// hold boot.dev's current version: it was saved after the course last changed there. boot.dev
// moves a course's last-updated time whenever one of its lessons changes, so a lesson saved
// later cannot have changed since. A lesson whose stored text still holds something the
// stripping rules now remove (stale) is loaded again too, so it is rewritten under those rules.
func due(l bootdev.LessonRef, s lessons.Stored, have bool, cc bootdev.Course, all, stale bool) string {
	switch {
	case !have:
		return "new"
	case all:
		return "asked for"
	case stale:
		return "with text the stripping rules now remove"
	case cc.LastUpdated.IsZero():
		return "in a course the catalog gives no date for"
	case !s.SyncedAt.Add(-freshness).After(cc.LastUpdated):
		return "in a course that changed after they were saved"
	case s.Title != l.Title:
		return "with a new title"
	}
	return ""
}

// fetchLesson loads one lesson and maps it to rows in its place.
func fetchLesson(ctx context.Context, c *bootdev.Client, o *outline, uuid string) (lessons.Record, error) {
	page := o.page
	if uuid != o.course.FirstLesson {
		var err error
		if page, err = c.LessonPage(ctx, uuid); err != nil {
			return lessons.Record{}, err
		}
	}
	loaded := time.Now()
	obj, err := bootdev.LessonFromPage(page, uuid)
	if err != nil {
		return lessons.Record{}, err
	}
	rec, err := lessons.Build(obj)
	if err != nil {
		return lessons.Record{}, err
	}
	p := o.places[uuid]
	rec.Lesson.ChapterUUID, rec.Lesson.Position, rec.Lesson.Required = p.ChapterUUID, p.Position, p.Required
	rec.Lesson.SyncedAt = lessons.UTC(loaded)
	return rec, nil
}
