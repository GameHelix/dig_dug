// Package authoring reads and writes lesson packages, the folders writers author lessons in,
// and maps them to and from a library's rows. Layout is the specification writers follow.
//
// A package has exactly one way to be written for a given lesson, so importing it and
// exporting it again gives back the same bytes. Read refuses anything that is not written that
// way, and its error shows the text it expects.
package authoring

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/jobloom/gopherwood/internal/media"
)

// Layout is the lesson package specification, as the author tool's help shows it.
const Layout = `A lesson package is a folder:

  README.md            the lesson's front matter, then its readme
  starter/             code lessons: the files the learner starts from
  solution/            code lessons: the solved version of every file the learner edits
  readonly.txt         code lessons, optional: starter files shown but not editable
  hidden.txt           code lessons, optional: starter files added at build time, never shown
  expected_output.txt  type code only: exactly what the solved program prints
  quiz.md              type quiz only: the questions and their answers

README.md starts with this block, every line exactly as shown, in this order:

  ---
  slug: launch-checklist
  title: The Launch Checklist
  type: code
  position: 0
  difficulty: 10
  topics: printing, variables
  ---

  slug        lowercase letters, digits and single hyphens; unique in its chapter
  title       the lesson's name
  type        code (passes when the program prints expected_output.txt exactly),
              code_tests (passes when go test passes) or quiz
  position    the lesson's place in its chapter, counted from 0; unique in its chapter
  difficulty  a whole number from 1 up
  topics      comma-separated, one space after each comma, in alphabetical order, no
              repeats; write "topics:" with nothing after it for none

Everything after the closing --- line is the readme, Markdown, kept byte for byte. Leave
out pictures, videos and HTML embeds: the app never shows them, and they are refused.

Code lessons (code, code_tests):
  - starter/ holds every file the learner gets, in any subfolders; at least one of them
    is editable. A code_tests lesson has at least one *_test.go file.
  - Files whose names end in _test.go are read-only. readonly.txt lists any other
    read-only files, and hidden.txt the hidden ones: one path per line, relative to
    starter/, with / between folders, in alphabetical order, each line ending in a newline.
    Leave a list out when it would be empty, and never list a _test.go file in readonly.txt.
  - The learner edits the files that are neither read-only nor hidden. solution/ holds the
    solved version of exactly those files, under the same paths, and nothing else.
  - The code is Go, built with the learner's own toolchain; it uses the standard library
    only. A go.mod in starter/ is optional.
  - Tests fail with t.Error, t.Errorf, t.Fatal or t.Fatalf: a test that only prints PASS or
    FAIL cannot fail, and library verify refuses it.
  - Every file is UTF-8 text, and none is a symbolic link.

Quizzes (quiz.md), every line exactly as shown:

  ## Which verb prints a value in Go's default format?

  - [ ] %d
  - [x] %v
  - [ ] %q

  ## Does fmt.Println add a newline?

  - [x] Yes
  - [ ] No

  A question is one "## " line, then a blank line, then its answers, at least two, one
  "- [ ] " or "- [x] " line each, exactly one of them [x], with no two alike. One blank
  line comes between questions, and the file ends right after the last answer's newline.

Nothing else belongs in a package. Files and folders whose names start with a dot are
ignored.`

// Package is one lesson as its package folder holds it.
type Package struct {
	Slug, Title string
	Type        string // code, code_tests or quiz
	Position    int64
	Difficulty  int64
	Topics      []string // in alphabetical order
	Readme      string

	Starter  []File  // code lessons, in name order
	Solution []File  // code lessons: one per editable starter file, in name order
	Expected *string // type code: what the solved program prints

	Questions []Question // quizzes
}

// File is a file of a code lesson. Name is its path inside the lesson, with / between folders.
type File struct {
	Name     string
	Content  string
	Hidden   bool
	ReadOnly bool
}

// Editable reports whether the learner edits the file.
func (f File) Editable() bool { return !f.Hidden && !f.ReadOnly }

// Question is a quiz question with its answers, exactly one of them right.
type Question struct {
	Text    string
	Answers []Answer
}

type Answer struct {
	Text  string
	Right bool
}

var reSlug = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// ValidSlug reports whether s is a slug: lowercase letters, digits and single hyphens.
func ValidSlug(s string) bool { return reSlug.MatchString(s) }

// Read reads and checks the package in dir.
func Read(dir string) (Package, error) {
	var p Package
	entries, err := os.ReadDir(dir)
	if err != nil {
		return p, err
	}
	present := map[string]bool{}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		present[e.Name()] = e.IsDir()
	}
	readme, err := readText(filepath.Join(dir, "README.md"))
	if err != nil {
		return p, err
	}
	if err := p.parseReadme(readme); err != nil {
		return p, fmt.Errorf("README.md: %w", err)
	}
	allowed := map[string]bool{"README.md": false}
	if p.Type == "quiz" {
		allowed["quiz.md"] = false
	} else {
		allowed["starter"], allowed["solution"], allowed["readonly.txt"], allowed["hidden.txt"] = true, true, false, false
		if p.Type == "code" {
			allowed["expected_output.txt"] = false
		}
	}
	for name, isDir := range present {
		if wantDir, ok := allowed[name]; !ok || wantDir != isDir {
			return p, fmt.Errorf("%s does not belong in a %s lesson's package", name, p.Type)
		}
	}
	if p.Type == "quiz" {
		text, err := readText(filepath.Join(dir, "quiz.md"))
		if err != nil {
			return p, err
		}
		if p.Questions, err = parseQuiz(text); err != nil {
			return p, fmt.Errorf("quiz.md: %w", err)
		}
	} else if err := p.readCode(dir, present); err != nil {
		return p, err
	}
	return p, p.checkMedia()
}

func readText(file string) (string, error) {
	b, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	if !utf8.Valid(b) {
		return "", fmt.Errorf("%s is not UTF-8 text", filepath.Base(file))
	}
	return string(b), nil
}

// ---- README.md ----

var frontKeys = []string{"slug", "title", "type", "position", "difficulty", "topics"}

func (p *Package) parseReadme(text string) error {
	if !strings.HasPrefix(text, "---\n") {
		return errors.New(`it must start with a front matter block: a "---" line, the keys, and another "---" line`)
	}
	end := strings.Index(text[4:], "\n---\n")
	if end < 0 {
		return errors.New(`its front matter block has no closing "---" line`)
	}
	block, readme := text[:4+end+5], text[4+end+5:]
	values := map[string]string{}
	for _, line := range strings.Split(text[4:4+end], "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok || !slices.Contains(frontKeys, key) {
			return fmt.Errorf("front matter line %q is not one of %s followed by a colon", line, strings.Join(frontKeys, ", "))
		}
		if _, dup := values[key]; dup {
			return fmt.Errorf("front matter has %s twice", key)
		}
		values[key] = strings.TrimSpace(value)
	}
	for _, k := range frontKeys {
		if _, ok := values[k]; !ok {
			return fmt.Errorf("front matter has no %s", k)
		}
	}
	p.Slug, p.Title, p.Readme = values["slug"], values["title"], readme
	switch {
	case !ValidSlug(p.Slug):
		return fmt.Errorf("slug %q is not lowercase letters, digits and single hyphens", p.Slug)
	case p.Title == "":
		return errors.New("title is empty")
	}
	p.Type = values["type"]
	if !slices.Contains([]string{"code", "code_tests", "quiz"}, p.Type) {
		return fmt.Errorf("type %q is not code, code_tests or quiz", p.Type)
	}
	var err error
	if p.Position, err = strconv.ParseInt(values["position"], 10, 64); err != nil || p.Position < 0 {
		return fmt.Errorf("position %q is not a whole number from 0 up", values["position"])
	}
	if p.Difficulty, err = strconv.ParseInt(values["difficulty"], 10, 64); err != nil || p.Difficulty < 1 {
		return fmt.Errorf("difficulty %q is not a whole number from 1 up", values["difficulty"])
	}
	if t := values["topics"]; t != "" {
		for _, topic := range strings.Split(t, ",") {
			if topic = strings.TrimSpace(topic); topic == "" {
				return errors.New("topics has an empty topic")
			}
			p.Topics = append(p.Topics, topic)
		}
	}
	sorted := slices.Clone(p.Topics)
	slices.Sort(sorted)
	if len(slices.Compact(sorted)) != len(p.Topics) {
		return errors.New("topics lists a topic twice")
	}
	p.Topics = sorted
	if want := p.frontMatter(); block != want {
		return fmt.Errorf("its front matter must read exactly:\n%s", want)
	}
	return nil
}

func (p Package) frontMatter() string {
	topics := ""
	if len(p.Topics) > 0 {
		topics = " " + strings.Join(p.Topics, ", ")
	}
	return "---\nslug: " + p.Slug + "\ntitle: " + p.Title + "\ntype: " + p.Type +
		"\nposition: " + strconv.FormatInt(p.Position, 10) + "\ndifficulty: " + strconv.FormatInt(p.Difficulty, 10) +
		"\ntopics:" + topics + "\n---\n"
}

// ---- Code ----

func (p *Package) readCode(dir string, present map[string]bool) error {
	if _, ok := present["starter"]; !ok {
		return errors.New("a code lesson's package needs a starter folder")
	}
	if _, ok := present["solution"]; !ok {
		return errors.New("a code lesson's package needs a solution folder")
	}
	starter, err := readTree(filepath.Join(dir, "starter"))
	if err != nil {
		return err
	}
	if len(starter) == 0 {
		return errors.New("starter/ is empty")
	}
	readonly, err := readList(dir, "readonly.txt", starter)
	if err != nil {
		return err
	}
	hidden, err := readList(dir, "hidden.txt", starter)
	if err != nil {
		return err
	}
	tests := 0
	for _, name := range sortedKeys(starter) {
		f := File{Name: name, Content: starter[name], Hidden: hidden[name], ReadOnly: readonly[name] || isTest(name)}
		if isTest(name) {
			tests++
			if readonly[name] {
				return fmt.Errorf("readonly.txt lists %s, a _test.go file, which is read-only anyway", name)
			}
		}
		p.Starter = append(p.Starter, f)
	}
	if p.Type == "code_tests" && tests == 0 {
		return errors.New("a code_tests lesson needs at least one _test.go file in starter/")
	}
	solution, err := readTree(filepath.Join(dir, "solution"))
	if err != nil {
		return err
	}
	editable := 0
	for _, f := range p.Starter {
		if !f.Editable() {
			continue
		}
		editable++
		content, ok := solution[f.Name]
		if !ok {
			return fmt.Errorf("solution/ has no %s, a file the learner edits", f.Name)
		}
		p.Solution = append(p.Solution, File{Name: f.Name, Content: content})
	}
	if editable == 0 {
		return errors.New("starter/ has no file the learner edits: every file is read-only or hidden")
	}
	for _, name := range sortedKeys(solution) {
		if i := slices.IndexFunc(p.Starter, func(f File) bool { return f.Name == name }); i < 0 || !p.Starter[i].Editable() {
			return fmt.Errorf("solution/%s solves no file the learner edits", name)
		}
	}
	if p.Type == "code" {
		out, err := readText(filepath.Join(dir, "expected_output.txt"))
		if err != nil {
			return fmt.Errorf("a code lesson needs expected_output.txt: %w", err)
		}
		p.Expected = &out
	}
	return nil
}

func isTest(name string) bool { return strings.HasSuffix(name, "_test.go") }

// readTree reads the files under root, by their paths relative to it.
func readTree(root string) (map[string]string, error) {
	files := map[string]string{}
	err := filepath.WalkDir(root, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if strings.HasPrefix(e.Name(), ".") && p != root {
			if e.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if e.IsDir() {
			return nil
		}
		if !e.Type().IsRegular() {
			return fmt.Errorf("%s is not a regular file", p)
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		text, err := readText(p)
		if err != nil {
			return err
		}
		files[filepath.ToSlash(rel)] = text
		return nil
	})
	return files, err
}

// readList reads readonly.txt or hidden.txt, which name starter files.
func readList(dir, name string, starter map[string]string) (map[string]bool, error) {
	text, err := readText(filepath.Join(dir, name))
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]bool{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	var names []string
	for _, line := range strings.SplitAfter(text, "\n") {
		if line == "" {
			continue
		}
		file, ok := strings.CutSuffix(line, "\n")
		if !ok || file == "" || strings.TrimSpace(file) != file {
			return nil, fmt.Errorf("%s: every line is one file name, without blanks around it, ending in a newline", name)
		}
		if _, ok := starter[file]; !ok {
			return nil, fmt.Errorf("%s lists %s, which is not in starter/", name, file)
		}
		out[file] = true
		names = append(names, file)
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("%s is empty: leave it out", name)
	}
	if want := listText(sortedKeys(out)); text != want {
		return nil, fmt.Errorf("%s must list each file once, in alphabetical order:\n%s", name, want)
	}
	return out, nil
}

func listText(names []string) string {
	var b strings.Builder
	for _, n := range names {
		b.WriteString(n + "\n")
	}
	return b.String()
}

// ---- quiz.md ----

func parseQuiz(text string) ([]Question, error) {
	var qs []Question
	lines := strings.Split(text, "\n")
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "## "):
			qs = append(qs, Question{Text: strings.TrimSpace(line[3:])})
		case strings.HasPrefix(line, "- [ ] "), strings.HasPrefix(line, "- [x] "):
			if len(qs) == 0 {
				return nil, fmt.Errorf("answer %q comes before any question", line)
			}
			q := &qs[len(qs)-1]
			q.Answers = append(q.Answers, Answer{Text: strings.TrimSpace(line[6:]), Right: line[3] == 'x'})
		case strings.TrimSpace(line) == "":
		default:
			return nil, fmt.Errorf(`line %q is neither a "## " question nor a "- [ ] " or "- [x] " answer`, line)
		}
	}
	if len(qs) == 0 {
		return nil, errors.New("there are no questions")
	}
	for i, q := range qs {
		right, seen := 0, map[string]bool{}
		if q.Text == "" {
			return nil, fmt.Errorf("question %d is empty", i+1)
		}
		if len(q.Answers) < 2 {
			return nil, fmt.Errorf("question %q has fewer than two answers", q.Text)
		}
		for _, a := range q.Answers {
			if a.Text == "" {
				return nil, fmt.Errorf("question %q has an empty answer", q.Text)
			}
			if seen[a.Text] {
				return nil, fmt.Errorf("question %q has the answer %q twice", q.Text, a.Text)
			}
			seen[a.Text] = true
			if a.Right {
				right++
			}
		}
		if right != 1 {
			return nil, fmt.Errorf("question %q has %d right answers, want exactly one", q.Text, right)
		}
	}
	if want := quizText(qs); text != want {
		return nil, fmt.Errorf("it must read exactly:\n%s", want)
	}
	return qs, nil
}

func quizText(qs []Question) string {
	var b strings.Builder
	for i, q := range qs {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString("## " + q.Text + "\n\n")
		for _, a := range q.Answers {
			mark := " "
			if a.Right {
				mark = "x"
			}
			b.WriteString("- [" + mark + "] " + a.Text + "\n")
		}
	}
	return b.String()
}

// checkMedia refuses pictures, videos and widgets in the text the app shows.
func (p Package) checkMedia() error {
	texts := map[string]string{"README.md": p.Readme}
	for i, q := range p.Questions {
		texts[fmt.Sprintf("question %d", i+1)] = q.Text
		for j, a := range q.Answers {
			texts[fmt.Sprintf("question %d, answer %d", i+1, j+1)] = a.Text
		}
	}
	for _, where := range sortedKeys(texts) {
		if _, st := media.Strip(texts[where]); st.Total() > 0 {
			return fmt.Errorf("%s holds %d pictures, %d videos, %d links to videos and %d widgets; the app shows none of them, so leave them out",
				where, st.Images, st.Videos, st.Links, st.Widgets)
		}
	}
	return nil
}

// ---- Writing ----

// Write writes the package into dir, which must not exist yet or be empty.
func (p Package) Write(dir string) error {
	if entries, err := os.ReadDir(dir); err == nil && len(entries) > 0 {
		return fmt.Errorf("%s is not empty", dir)
	}
	files := map[string]string{"README.md": p.frontMatter() + p.Readme}
	if p.Type == "quiz" {
		files["quiz.md"] = quizText(p.Questions)
	} else {
		var readonly, hidden []string
		for _, f := range p.Starter {
			files[path.Join("starter", f.Name)] = f.Content
			if f.ReadOnly && !isTest(f.Name) {
				readonly = append(readonly, f.Name)
			}
			if f.Hidden {
				hidden = append(hidden, f.Name)
			}
		}
		for _, f := range p.Solution {
			files[path.Join("solution", f.Name)] = f.Content
		}
		if len(readonly) > 0 {
			files["readonly.txt"] = listText(readonly)
		}
		if len(hidden) > 0 {
			files["hidden.txt"] = listText(hidden)
		}
		if p.Expected != nil {
			files["expected_output.txt"] = *p.Expected
		}
	}
	for _, name := range sortedKeys(files) {
		file := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(file, []byte(files[name]), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}
