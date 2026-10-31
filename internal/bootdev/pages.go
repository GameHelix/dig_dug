package bootdev

import (
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Course is one entry of boot.dev's course catalog.
type Course struct {
	UUID, Slug, Title string
	Kind              string // typeDescription: "Course", "Guided Project", "Portfolio Project"
	Language          string // "go", "python", "any", ...
	ShortDescription  string
	Description       string
	Status            string
	FirstLesson       string    // the uuid of its first lesson, whose page holds the outline
	NumLessons        int       // as the catalog counts them
	LastUpdated       time.Time // when a lesson of the course last changed; zero if not given
	Chapters          []CatalogChapter
	Alternatives      map[string]string // language -> slug of the same course in that language
	Technologies      []string          // technologiesUsed, displayTechnologies and keywords
	Position          int               // 0-based, among the courses of its language, in catalog order
}

// CatalogChapter is a chapter as the catalog describes it.
type CatalogChapter struct {
	UUID, Slug, Title, Description string
	NumLessons                     int
}

// ParseCatalog reads every entry of the catalog page's data, in catalog order.
func ParseCatalog(root map[string]any) ([]Course, error) {
	all, ok := dig(root, "data", "coursesOverview").([]any)
	if !ok || len(all) == 0 {
		return nil, errors.New("no courses on the catalog page")
	}
	var out []Course
	for _, v := range all {
		m, ok := v.(map[string]any)
		if !ok {
			continue
		}
		c := Course{
			UUID:             str(m["uuid"]),
			Slug:             str(m["slug"]),
			Title:            str(m["title"]),
			Kind:             str(m["typeDescription"]),
			Language:         str(m["language"]),
			ShortDescription: strings.TrimSpace(str(m["shortDescription"])),
			Description:      strings.TrimSpace(str(m["description"])),
			Status:           str(m["status"]),
			FirstLesson:      str(m["firstLessonUUID"]),
			NumLessons:       num(m["numLessons"]),
			Alternatives:     map[string]string{},
		}
		if c.UUID == "" || c.Slug == "" {
			continue
		}
		if t, err := time.Parse(time.RFC3339, str(m["lastUpdated"])); err == nil {
			c.LastUpdated = t.UTC()
		}
		if alts, ok := m["alternatives"].(map[string]any); ok {
			for lang, slug := range alts {
				c.Alternatives[lang] = str(slug)
			}
		}
		for _, k := range []string{"technologiesUsed", "displayTechnologies", "keywords"} {
			list, _ := m[k].([]any)
			for _, t := range list {
				if s := str(t); s != "" {
					c.Technologies = append(c.Technologies, s)
				}
			}
		}
		chapters, _ := m["chapters"].([]any)
		for _, cv := range chapters {
			ch, ok := cv.(map[string]any)
			if !ok || str(ch["uuid"]) == "" {
				continue
			}
			c.Chapters = append(c.Chapters, CatalogChapter{
				UUID:        str(ch["uuid"]),
				Slug:        str(ch["slug"]),
				Title:       str(ch["title"]),
				Description: strings.TrimSpace(str(ch["description"])),
				NumLessons:  num(ch["numLessons"]),
			})
		}
		out = append(out, c)
	}
	if len(out) == 0 {
		return nil, errors.New("no courses on the catalog page")
	}
	return out, nil
}

// OfLanguage returns the catalog entries of one language, numbered from 0 in catalog order.
func OfLanguage(all []Course, lang string) []Course {
	var out []Course
	for _, c := range all {
		if c.Language == lang {
			c.Position = len(out)
			out = append(out, c)
		}
	}
	return out
}

// Chapter is a chapter of a course's outline, with its lessons in order.
type Chapter struct {
	UUID, Title string
	Lessons     []LessonRef
}

// LessonRef is a lesson as a course's outline lists it.
type LessonRef struct {
	UUID, Title string
	Required    bool
}

// ParseOutline reads a course's chapters and lessons, in order, from any lesson page of it.
func ParseOutline(root map[string]any, courseUUID string) ([]Chapter, error) {
	list, ok := dig(root, "pinia", "courses", "courseProgress", courseUUID, "chapters").([]any)
	if !ok || len(list) == 0 {
		return nil, errors.New("the course outline is not on its lesson page")
	}
	var out []Chapter
	for _, v := range list {
		m, _ := v.(map[string]any)
		ch := Chapter{UUID: str(m["uuid"]), Title: str(m["title"])}
		lessons, _ := m["lessons"].([]any)
		for _, lv := range lessons {
			l, _ := lv.(map[string]any)
			if id := str(l["uuid"]); id != "" {
				ch.Lessons = append(ch.Lessons, LessonRef{UUID: id, Title: str(l["title"]), Required: l["isRequired"] == true})
			}
		}
		if ch.UUID != "" {
			out = append(out, ch)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("the course outline is empty")
	}
	return out, nil
}

// LessonFromPage returns the lesson object a lesson page was rendered for.
func LessonFromPage(root map[string]any, uuid string) (map[string]any, error) {
	l, ok := dig(root, "pinia", "courses", "lessons", uuid, "lesson").(map[string]any)
	if !ok || str(l["uuid"]) != uuid {
		return nil, errors.New("the lesson is not on its page")
	}
	return l, nil
}

func dig(v any, keys ...string) any {
	for _, k := range keys {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[k]
	}
	return v
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

func num(v any) int {
	switch n := v.(type) {
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	case float64:
		return int(n)
	}
	return 0
}
