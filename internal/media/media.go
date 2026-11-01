// Package media finds and removes pictures, videos, embeds and widgets in lesson Markdown.
//
// A library holds none of them: the app shows lessons as text, offline. Markdown shows pictures
// with image syntax and <img>, embeds videos as "images" that point at an .mp4 or as <video> and
// <iframe> players, and links to videos on sites such as YouTube. Strip removes all of that and
// keeps the text around it. Code is never touched: fenced and indented code blocks and code
// spans stay exactly as they are, because a lesson may teach HTML or Markdown, and its examples
// (an <img> in a test page, an <iframe> in a security example, the image syntax for a README
// badge) must stay whole.
package media

import (
	"net/url"
	"path"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/text"
)

// Stats counts what Strip removed.
type Stats struct {
	Images  int // pictures: Markdown and HTML images, <picture>, <svg>
	Videos  int // videos and players: video files embedded as images, <video>, <audio>, <iframe>, <embed>, <object>
	Links   int // links that led only to a video file or a video player
	Widgets int // interactive widgets: ```widget fences and the settings in them
}

func (s Stats) Total() int { return s.Images + s.Videos + s.Links + s.Widgets }

// Strip returns md without pictures and videos, and what it removed.
//
//   - An image goes, and its alt text stays only if it reads as content: in the middle of a
//     sentence it keeps the sentence whole; on its own line only a full sentence is kept, not a
//     label like "struct layout". A video's alt text never stays.
//   - <img>, <picture>, <svg>, <video>, <audio>, <iframe>, <embed>, <object>, <source> and
//     <track> go, with whatever they contain.
//   - A link to a video file or player becomes its plain text; one that stands alone on its
//     line goes. Bare and <angle> links to videos go, and so do links an image was the only
//     content of, and reference definitions only images or videos used.
//   - A line left empty goes too, without leaving a double blank line behind.
func Strip(md string) (string, Stats) {
	var st Stats
	if !strings.ContainsAny(md, "[<") && !strings.Contains(md, "://") && !strings.Contains(md, "widget") {
		return md, st
	}
	md = removeWidgets(md, &st)
	defs := findDefinitions(md, codeSpans(md))
	usedByImage := map[string]bool{}
	md = removeImages(md, defs, usedByImage, &st)
	md = removeVideoLinks(md, &st)
	md = removeBareVideoURLs(md, usedByImage, &st)
	return md, st
}

// removeWidgets takes out the fenced blocks that set up interactive widgets: a fence whose
// language is widget, holding the widget's settings as JSON, such as
//
//	```widget fuel-gauge
//	{"tank": 100, "burn": 30}
//	```
//
// A widget runs only on the website it was made for. The whole fence goes, and the text around
// it stays, even where it mentions the widget. Fences of any other language are lesson content
// and stay.
func removeWidgets(md string, st *Stats) string {
	if !strings.Contains(md, "widget") {
		return md
	}
	src := []byte(md)
	type cut struct {
		start, end int
		prefix     string // the container markers of the fence's lines, such as "> "
	}
	var cuts []cut
	doc := mdParser.Parse(text.NewReader(src))
	_ = ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		f, ok := n.(*ast.FencedCodeBlock)
		if !entering || !ok {
			return ast.WalkContinue, nil
		}
		if f.Info == nil || string(f.Language(src)) != "widget" {
			return ast.WalkSkipChildren, nil
		}
		start := lineStart(md, f.Info.Segment.Start)
		end := nextLine(md, f.Info.Segment.Start) // after the opening fence
		if lines := f.Lines(); lines.Len() > 0 {
			end = nextLine(md, max(lines.At(lines.Len()-1).Stop-1, end))
		}
		opening := md[start:nextLine(md, start)]
		prefix := opening[:len(opening)-len(strings.TrimLeft(opening, " \t>"))]
		if end < len(md) && reClosingFence.MatchString(md[end:nextLine(md, end)]) {
			end = nextLine(md, end) // the closing fence; an unclosed fence ends with its content
		}
		cuts = append(cuts, cut{start, end, prefix})
		return ast.WalkSkipChildren, nil
	})
	for i := len(cuts) - 1; i >= 0; i-- {
		c := cuts[i]
		blankBefore := c.start == 0 || isBlankLine(md[lineStart(md, c.start-1):c.start])
		blankAfter := c.end >= len(md) || isBlankLine(md[c.end:nextLine(md, c.end)])
		repl := ""
		switch {
		case c.end >= len(md): // at the very end: no blank lines left dangling either
			for c.start > 0 && isBlankLine(md[lineStart(md, c.start-1):c.start]) {
				c.start = lineStart(md, c.start-1)
			}
		case blankBefore && blankAfter:
			c.end = nextLine(md, c.end) // one blank line stays between the blocks around it
		case !blankBefore && !blankAfter:
			repl = strings.TrimRight(c.prefix, " \t") + "\n" // keep the blocks around it apart
		}
		md = md[:c.start] + repl + md[c.end:]
		st.Widgets++
	}
	return md
}

var reClosingFence = regexp.MustCompile("^[ \t>]*(?:`{3,}|~{3,})[ \t]*\r?\n?$")

// lineStart returns where the line holding md[i] starts.
func lineStart(md string, i int) int { return strings.LastIndexByte(md[:i], '\n') + 1 }

// nextLine returns where the line after the one holding md[i] starts, or len(md).
func nextLine(md string, i int) int {
	if j := strings.IndexByte(md[i:], '\n'); j >= 0 {
		return i + j + 1
	}
	return len(md)
}

func isBlankLine(line string) bool { return strings.Trim(line, " \t>\r\n") == "" }

// removeImages takes out Markdown images and HTML picture, video and player elements.
func removeImages(md string, defs map[string]string, usedByImage map[string]bool, st *Stats) string {
	code := codeSpans(md)
	var edits []edit
	for _, l := range findLinks(md, code, defs, true) {
		alt := md[l.textStart:l.textEnd]
		e := edit{start: l.start, end: l.end}
		alone := isAlone(md, l.start, l.end)
		if !isVideoURL(l.dest) && altReadsAsContent(alt, !alone) {
			e.repl = strings.TrimSpace(alt) // a video's alt only names what is gone, so it never stays
		}
		e.kind = 'i'
		if isVideoURL(l.dest) {
			e.kind = 'v'
		}
		if l.label != "" {
			usedByImage[l.label] = true
		}
		edits = append(edits, e)
	}
	for _, m := range reMediaTag.FindAllStringSubmatchIndex(md, -1) {
		start, end := m[0], m[1]
		if code.contains(start) {
			continue
		}
		name := strings.ToLower(md[m[2]:m[3]])
		tag := md[start:end]
		if pairedMedia[name] && !strings.HasSuffix(tag, "/>") {
			if c := closingTag(md, end, name); c > 0 && !code.contains(c-1) {
				end = c
			}
		}
		e := edit{start: start, end: end, kind: 'v'}
		switch name {
		case "img", "picture", "svg":
			e.kind = 'i'
			if name == "img" {
				if alt := attr(tag, "alt"); altReadsAsContent(alt, !isAlone(md, start, end)) {
					e.repl = strings.TrimSpace(alt)
				}
			}
		}
		edits = append(edits, e)
	}
	return applyEdits(md, edits, st)
}

// removeVideoLinks turns links to videos into their text and drops links left without text.
func removeVideoLinks(md string, st *Stats) string {
	code := codeSpans(md)
	defs := findDefinitions(md, code)
	var edits []edit
	for _, l := range findLinks(md, code, defs, false) {
		linkText := md[l.textStart:l.textEnd]
		switch {
		case isVideoURL(l.dest):
			e := edit{start: l.start, end: l.end, repl: linkText, kind: 'l'}
			if isAlone(md, l.start, l.end) {
				e.repl = ""
			}
			edits = append(edits, e)
		case strings.TrimSpace(linkText) == "":
			edits = append(edits, edit{start: l.start, end: l.end}) // only an image was in it
		}
	}
	for _, m := range reAnchor.FindAllStringSubmatchIndex(md, -1) {
		if code.contains(m[0]) {
			continue
		}
		inner := md[m[4]:m[5]]
		switch {
		case isVideoURL(attr(md[m[0]:m[3]+1], "href")):
			e := edit{start: m[0], end: m[1], repl: inner, kind: 'l'}
			if isAlone(md, m[0], m[1]) {
				e.repl = ""
			}
			edits = append(edits, e)
		case strings.TrimSpace(inner) == "":
			edits = append(edits, edit{start: m[0], end: m[1]})
		}
	}
	return applyEdits(md, edits, st)
}

// removeBareVideoURLs drops <angle> and bare links to videos, and the reference definitions
// that nothing but removed images or videos used.
func removeBareVideoURLs(md string, usedByImage map[string]bool, st *Stats) string {
	code := codeSpans(md)
	defs := findDefinitionLines(md, code)
	labels := map[string]string{}
	for _, d := range defs {
		labels[d.label] = d.dest
	}
	links := findLinks(md, code, labels, false)
	inLink := func(i int) bool {
		for _, l := range links {
			if i >= l.start && i < l.end {
				return true
			}
		}
		return false
	}
	used := map[string]bool{}
	for _, l := range links {
		if l.label != "" {
			used[l.label] = true
		}
	}
	for _, l := range findLinks(md, code, labels, true) { // images that were not removed: none, but keep their definitions
		if l.label != "" {
			used[l.label] = true
		}
	}

	var edits []edit
	for _, d := range defs {
		if !used[d.label] && (usedByImage[d.label] || isVideoURL(d.dest) || isImageURL(d.dest)) {
			edits = append(edits, edit{start: d.start, end: d.end})
		}
	}
	for _, m := range reBareURL.FindAllStringIndex(md, -1) {
		start, end := m[0], m[1]
		raw := strings.TrimRight(md[start:end], ".,;:!?'\"")
		end = start + len(raw)
		if code.contains(start) || inLink(start) || inDefinition(defs, start) {
			continue
		}
		if start > 0 && md[start-1] == '<' && end < len(md) && md[end] == '>' {
			start, end = start-1, end+1 // an <autolink>
		} else if start > 0 && strings.ContainsRune(`("'=`, rune(md[start-1])) {
			continue // inside an attribute or someone's parentheses: leave it to the passes above
		}
		if isVideoURL(raw) {
			edits = append(edits, edit{start: start, end: end, kind: 'l'})
		}
	}
	return applyEdits(md, edits, st)
}

func inDefinition(defs []definition, i int) bool {
	for _, d := range defs {
		if i >= d.start && i < d.end {
			return true
		}
	}
	return false
}

var (
	// reMediaTag matches the opening tag of an HTML element that shows a picture or plays media.
	reMediaTag = regexp.MustCompile(`(?i)<(img|picture|svg|video|audio|iframe|embed|object|source|track)\b(?:[^>"']|"[^"]*"|'[^']*')*>`)
	reAnchor   = regexp.MustCompile(`(?is)<a\b((?:[^>"']|"[^"]*"|'[^']*')*)>(.*?)</a\s*>`)
	reBareURL  = regexp.MustCompile(`https?://[^\s<>()\[\]"'` + "`" + `]+`)
)

// pairedMedia lists the media elements removed together with their content.
var pairedMedia = map[string]bool{"picture": true, "svg": true, "video": true, "audio": true, "iframe": true, "object": true}

// closingTag returns the end of the </name> that closes an element opened before from, or -1.
func closingTag(md string, from int, name string) int {
	re := regexp.MustCompile(`(?i)</` + regexp.QuoteMeta(name) + `\s*>`)
	if loc := re.FindStringIndex(md[from:]); loc != nil {
		return from + loc[1]
	}
	return -1
}

var reAttr = regexp.MustCompile(`(?is)\s([a-z][a-z0-9:-]*)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+)`)

// attr returns the value of an attribute of an HTML tag.
func attr(tag, name string) string {
	for _, m := range reAttr.FindAllStringSubmatch(tag, -1) {
		if strings.EqualFold(m[1], name) {
			return strings.Trim(m[2], `"'`)
		}
	}
	return ""
}

var (
	// rePlaceholderAlt matches alt text that says nothing: "image", "alt text goes here", a file
	// name, a URL, a template name like IMAGE_URL.
	rePlaceholderAlt = regexp.MustCompile(`(?i)^(?:alt(?:[ -]?text)?(?: goes here)?|image|img|picture|pic|photo|screenshot|diagram|chart|graph|figure|illustration|drawing|logo|icon|gif|video|clip|movie|animation|meme|comic|thumbnail|banner|placeholder|todo|untitled|\S+\.(?:png|jpe?g|gif|webp|svg|avif|bmp|mp4|mov|webm)|https?://\S+)$|^[A-Z0-9]*_[A-Z0-9_]*$`)
	// rePictureWords finds alt text that describes the picture rather than the lesson.
	rePictureWords = regexp.MustCompile(`(?i)\b(?:diagram|chart|graph|screenshot|screen shot|image|picture|photo|illustration|figure|logo|icon|meme|gif|video|clip|thumbnail|banner|explainer|comic|xkcd|drawing|visual|animation)s?\b`)
)

// altReadsAsContent reports whether an image's alt text is worth keeping as text once the image
// is gone. In the middle of a sentence it is part of that sentence. On its own line it must be
// a sentence itself, and not one about the picture.
func altReadsAsContent(alt string, inSentence bool) bool {
	raw := strings.TrimSpace(alt)
	if raw == "" || rePlaceholderAlt.MatchString(raw) || strings.Contains(raw, "![") {
		return false
	}
	a := strings.Join(strings.Fields(strings.NewReplacer("*", "", "`", "").Replace(raw)), " ")
	if a == "" {
		return false
	}
	if inSentence {
		return true
	}
	if rePictureWords.MatchString(a) {
		return false
	}
	return len(strings.Fields(a)) >= 4 && strings.ContainsRune(".!?", rune(a[len(a)-1]))
}

var videoExts = []string{".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".ogv", ".wmv", ".flv", ".3gp", ".m3u8", ".mpd"}
var imageExts = []string{".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".bmp", ".ico", ".tif", ".tiff", ".heic"}

var reVimeoVideo = regexp.MustCompile(`^/(?:\d+|video/\d+|channels/[^/]+/\d+|groups/[^/]+/videos/\d+|showcase/\d+)`)

// isVideoURL reports whether a URL points at a video file or a page that only plays a video.
func isVideoURL(raw string) bool {
	raw = strings.Trim(strings.TrimSpace(raw), "<>")
	u, err := url.Parse(raw)
	if err != nil || raw == "" {
		return false
	}
	if slices.Contains(videoExts, strings.ToLower(path.Ext(u.Path))) {
		return true
	}
	host := strings.ToLower(u.Hostname())
	for _, p := range []string{"www.", "m."} {
		host = strings.TrimPrefix(host, p)
	}
	p := u.Path
	has := func(prefixes ...string) bool {
		for _, x := range prefixes {
			if strings.HasPrefix(p, x) {
				return true
			}
		}
		return false
	}
	switch host {
	case "youtu.be":
		return len(p) > 1
	case "youtube.com", "youtube-nocookie.com":
		return p == "/watch" || p == "/playlist" || has("/embed/", "/shorts/", "/live/", "/v/")
	case "vimeo.com":
		return reVimeoVideo.MatchString(p)
	case "player.vimeo.com", "player.twitch.tv", "clips.twitch.tv", "dai.ly", "fast.wistia.net", "fast.wistia.com":
		return true
	case "loom.com":
		return has("/share/", "/embed/")
	case "twitch.tv":
		return has("/videos/")
	case "dailymotion.com":
		return has("/video/", "/embed/")
	case "streamable.com":
		return len(p) > 1
	case "tiktok.com":
		return strings.Contains(p, "/video/")
	}
	return strings.HasSuffix(host, ".wistia.com") && has("/medias/")
}

// isImageURL reports whether a URL points at a picture file.
func isImageURL(raw string) bool {
	u, err := url.Parse(strings.Trim(strings.TrimSpace(raw), "<>"))
	return err == nil && slices.Contains(imageExts, strings.ToLower(path.Ext(u.Path)))
}

// ---- Where the code is ----

type span struct{ start, end int }

type spans []span

func (s spans) contains(i int) bool {
	k := sort.Search(len(s), func(k int) bool { return s[k].end > i })
	return k < len(s) && s[k].start <= i
}

// at returns the span holding i, or false.
func (s spans) at(i int) (span, bool) {
	k := sort.Search(len(s), func(k int) bool { return s[k].end > i })
	if k < len(s) && s[k].start <= i {
		return s[k], true
	}
	return span{}, false
}

var mdParser = goldmark.New().Parser()

var reRawCode = regexp.MustCompile(`(?is)<(pre|code)\b[^>]*>.*?</(?:pre|code)\s*>`)

// codeSpans returns the parts of md that are code, as CommonMark reads it: the lines of fenced
// and indented code blocks, code spans with their backticks, and <pre> and <code> elements.
func codeSpans(md string) spans {
	src := []byte(md)
	var out spans
	add := func(start, end int) {
		if start < end {
			out = append(out, span{start, end})
		}
	}
	doc := mdParser.Parse(text.NewReader(src))
	_ = ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		switch n := n.(type) {
		case *ast.FencedCodeBlock, *ast.CodeBlock:
			lines := n.Lines()
			for i := 0; i < lines.Len(); i++ {
				seg := lines.At(i)
				add(seg.Start, seg.Stop)
			}
			return ast.WalkSkipChildren, nil
		case *ast.HTMLBlock:
			if n.HTMLBlockType == ast.HTMLBlockType1 { // <pre>, <script>, <style>, <textarea>
				lines := n.Lines()
				if lines.Len() > 0 {
					add(lines.At(0).Start, lines.At(lines.Len()-1).Stop)
				}
				return ast.WalkSkipChildren, nil
			}
		case *ast.CodeSpan:
			start, end := -1, -1
			for c := n.FirstChild(); c != nil; c = c.NextSibling() {
				if t, ok := c.(*ast.Text); ok {
					if start < 0 {
						start = t.Segment.Start
					}
					end = t.Segment.Stop
				}
			}
			if start >= 0 {
				for start > 0 && (src[start-1] == '`' || src[start-1] == ' ') {
					start--
				}
				for end < len(src) && (src[end] == '`' || src[end] == ' ') {
					end++
				}
				add(start, end)
			}
			return ast.WalkSkipChildren, nil
		}
		return ast.WalkContinue, nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].start < out[j].start })
	for _, m := range reRawCode.FindAllStringIndex(md, -1) {
		if !out.contains(m[0]) {
			out = append(out, span{m[0], m[1]})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].start < out[j].start })
	merged := out[:0]
	for _, s := range out {
		if n := len(merged); n > 0 && s.start <= merged[n-1].end {
			merged[n-1].end = max(merged[n-1].end, s.end)
			continue
		}
		merged = append(merged, s)
	}
	return merged
}

// ---- Links and images ----

// link is a Markdown link or image: [text](dest), [text][label], [text][] or [text].
type link struct {
	start, end         int // the whole construct, from "[" or "![" on
	textStart, textEnd int // the text or alt inside the brackets
	dest               string
	label              string // normalized reference label; "" for an inline link
	image              bool
}

// findLinks returns the images (images true) or the links (images false) of md outside code,
// in order. Links inside a link's text are not looked for; images inside a link's text are.
func findLinks(md string, code spans, defs map[string]string, images bool) []link {
	var out []link
	for i := 0; i < len(md); i++ {
		if s, ok := code.at(i); ok {
			i = s.end - 1
			continue
		}
		switch md[i] {
		case '\\':
			i++
			continue
		case '[':
		default:
			continue
		}
		isImage := i > 0 && md[i-1] == '!' && !escaped(md, i-1) && !code.contains(i-1)
		l, ok := parseLink(md, i, code, defs)
		if !ok {
			continue
		}
		l.image = isImage
		if isImage {
			l.start = i - 1
		}
		if isImage == images {
			out = append(out, l)
			i = l.end - 1
		}
		// Otherwise go on inside the brackets: a link's text may hold an image.
	}
	return out
}

// escaped reports whether md[i] is preceded by an odd number of backslashes.
func escaped(md string, i int) bool {
	n := 0
	for j := i - 1; j >= 0 && md[j] == '\\'; j-- {
		n++
	}
	return n%2 == 1
}

// parseLink parses the link or image whose text opens with the "[" at md[i].
func parseLink(md string, i int, code spans, defs map[string]string) (link, bool) {
	depth := 0
	j := i
	for ; j < len(md); j++ {
		if s, ok := code.at(j); ok {
			j = s.end - 1
			continue
		}
		c := md[j]
		if c == '\\' {
			j++
			continue
		}
		if c == '[' {
			depth++
		} else if c == ']' {
			if depth--; depth == 0 {
				break
			}
		} else if c == '\n' && strings.TrimLeft(lineAt(md, j+1), " \t") == "" {
			return link{}, false // link text never spans a blank line
		}
	}
	if j >= len(md) {
		return link{}, false
	}
	l := link{start: i, textStart: i + 1, textEnd: j}
	k := j + 1
	if k < len(md) && md[k] == '(' {
		if dest, end, ok := parseDestination(md, k); ok {
			l.end, l.dest = end, dest
			return l, true
		}
	}
	if k < len(md) && md[k] == '[' {
		if m := strings.IndexAny(md[k+1:], "[]"); m >= 0 && md[k+1+m] == ']' {
			label := md[k+1 : k+1+m]
			if label == "" {
				label = md[l.textStart:l.textEnd]
			}
			if dest, ok := defs[normLabel(label)]; ok {
				l.end, l.dest, l.label = k+m+2, dest, normLabel(label)
				return l, true
			}
		}
	}
	if dest, ok := defs[normLabel(md[l.textStart:l.textEnd])]; ok && !(k < len(md) && md[k] == ':') {
		l.end, l.dest, l.label = k, dest, normLabel(md[l.textStart:l.textEnd])
		return l, true
	}
	return link{}, false
}

// lineAt returns the line that starts at i.
func lineAt(md string, i int) string {
	if i >= len(md) {
		return ""
	}
	if n := strings.IndexByte(md[i:], '\n'); n >= 0 {
		return md[i : i+n]
	}
	return md[i:]
}

// parseDestination parses "(dest "title")" starting at the "(" at md[k] and returns the
// destination and the end of the construct.
func parseDestination(md string, k int) (string, int, bool) {
	p := skipSpace(md, k+1)
	var dest string
	if p < len(md) && md[p] == '<' {
		q := p + 1
		for q < len(md) && md[q] != '>' && md[q] != '\n' {
			if md[q] == '\\' {
				q++
			}
			q++
		}
		if q >= len(md) || md[q] != '>' {
			return "", 0, false
		}
		dest, p = md[p+1:q], q+1
	} else {
		depth, q := 0, p
		for q < len(md) {
			c := md[q]
			if c == '\\' && q+1 < len(md) {
				q += 2
				continue
			}
			if c == '(' {
				depth++
			} else if c == ')' {
				if depth == 0 {
					break
				}
				depth--
			} else if c <= ' ' {
				break
			}
			q++
		}
		dest, p = md[p:q], q
	}
	p = skipSpace(md, p)
	if p < len(md) && (md[p] == '"' || md[p] == '\'' || md[p] == '(') {
		closer := md[p]
		if closer == '(' {
			closer = ')'
		}
		q := p + 1
		for q < len(md) && md[q] != closer {
			if md[q] == '\\' {
				q++
			}
			q++
		}
		if q >= len(md) {
			return "", 0, false
		}
		p = skipSpace(md, q+1)
	}
	if p < len(md) && md[p] == ')' {
		return dest, p + 1, true
	}
	return "", 0, false
}

// skipSpace skips spaces and tabs and at most one line break.
func skipSpace(md string, p int) int {
	nl := false
	for p < len(md) {
		switch md[p] {
		case ' ', '\t':
		case '\n':
			if nl {
				return p
			}
			nl = true
		default:
			return p
		}
		p++
	}
	return p
}

func normLabel(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

// definition is a link reference definition: [label]: dest "title".
type definition struct {
	label, dest string
	start, end  int // the whole line, with its line break
}

var reDefinition = regexp.MustCompile(`(?m)^ {0,3}\[((?:[^\[\]\\]|\\.)+)\]:[ \t]*(?:\n[ \t]*)?(<[^>\n]*>|\S+)(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?[ \t]*(?:\n|$)`)

func findDefinitionLines(md string, code spans) []definition {
	var out []definition
	for _, m := range reDefinition.FindAllStringSubmatchIndex(md, -1) {
		if code.contains(m[0]) {
			continue
		}
		out = append(out, definition{
			label: normLabel(md[m[2]:m[3]]),
			dest:  strings.Trim(md[m[4]:m[5]], "<>"),
			start: m[0], end: m[1],
		})
	}
	return out
}

func findDefinitions(md string, code spans) map[string]string {
	out := map[string]string{}
	for _, d := range findDefinitionLines(md, code) {
		if _, dup := out[d.label]; !dup {
			out[d.label] = d.dest // the first definition of a label wins
		}
	}
	return out
}

// ---- Editing ----

type edit struct {
	start, end int
	repl       string
	kind       byte // what it removes, for the counts: 'i' image, 'v' video, 'l' video link, 0 nothing to count
}

var reLineMarkers = regexp.MustCompile(`^[ \t]*(?:>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|$))?(?:\[[ xX]\](?:[ \t]+|$))?`)

// isAlone reports whether md[start:end] is the only content of its line, apart from list,
// quote and task markers and a link around it.
func isAlone(md string, start, end int) bool {
	ls := strings.LastIndexByte(md[:start], '\n') + 1
	le := strings.IndexByte(md[end:], '\n')
	if le < 0 {
		le = len(md)
	} else {
		le += end
	}
	before := strings.TrimRight(md[ls:start], " \t")
	before = strings.TrimSuffix(before, "[") // an enclosing link: [![alt](img)](href)
	before = before[len(reLineMarkers.FindString(before)):]
	after := md[end:le]
	if strings.HasPrefix(after, "](") {
		if _, e, ok := parseDestination(after, 1); ok {
			after = after[e:]
		}
	}
	return strings.TrimSpace(before) == "" && strings.TrimSpace(after) == ""
}

// applyEdits makes the edits, outermost first when they overlap, counts what they removed, and
// then removes the lines an edit left empty.
func applyEdits(md string, edits []edit, st *Stats) string {
	if len(edits) == 0 {
		return md
	}
	sort.Slice(edits, func(i, j int) bool {
		if edits[i].start != edits[j].start {
			return edits[i].start < edits[j].start
		}
		return edits[i].end > edits[j].end
	})
	var b strings.Builder
	var marks []int
	last := 0
	for _, e := range edits {
		if e.start < last {
			continue // inside an edit already made, like a <source> inside a <video>
		}
		switch e.kind {
		case 'i':
			st.Images++
		case 'v':
			st.Videos++
		case 'l':
			st.Links++
		}
		start, end := e.start, e.end
		if e.repl == "" && start > 0 && md[start-1] == ' ' && (end == len(md) || strings.ContainsRune(" .,;:!?)\n", rune(md[end]))) {
			start-- // "see ![x](y) here" becomes "see here", not "see  here"
		}
		b.WriteString(md[last:start])
		marks = append(marks, b.Len())
		b.WriteString(e.repl)
		last = end
	}
	b.WriteString(md[last:])
	return dropEmptiedLines(b.String(), marks, strings.HasSuffix(md, "\n"))
}

// dropEmptiedLines removes the lines at marks that hold nothing but list, quote or task markers,
// and one of the blank lines that would then be next to each other.
func dropEmptiedLines(s string, marks []int, endsWithNewline bool) string {
	lines := strings.SplitAfter(s, "\n")
	starts := make([]int, len(lines))
	for i, pos := 1, 0; i < len(lines); i++ {
		pos += len(lines[i-1])
		starts[i] = pos
	}
	drop := map[int]bool{}
	for _, m := range marks {
		i := sort.Search(len(starts), func(i int) bool { return starts[i] > m }) - 1
		line := strings.TrimSuffix(lines[i], "\n")
		if strings.TrimSpace(line[len(reLineMarkers.FindString(line)):]) == "" {
			drop[i] = true
		}
	}
	if len(drop) == 0 {
		return s
	}
	blank := func(l string) bool { return strings.Trim(l, " \t>\r\n") == "" }
	var kept []string
	afterDrop := false
	for i, l := range lines {
		if drop[i] {
			afterDrop = true
			continue
		}
		if afterDrop && blank(l) && (len(kept) == 0 || blank(kept[len(kept)-1])) {
			continue // the blank line on the other side of a dropped one, or at the very top
		}
		afterDrop = false
		kept = append(kept, l)
	}
	if !afterDrop {
		return strings.Join(kept, "")
	}
	// The text ended with dropped lines: leave no blank lines dangling at its end.
	for len(kept) > 0 && blank(kept[len(kept)-1]) {
		kept = kept[:len(kept)-1]
	}
	out := strings.Join(kept, "")
	if !endsWithNewline {
		out = strings.TrimSuffix(out, "\n")
	}
	return out
}
