package media

// Every example here is invented.

import (
	"strings"
	"testing"
)

func TestStripMedia(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   string
		want string
		st   Stats
	}{
		{
			name: "markdown image on its own line, with its label alt",
			in:   "Intro.\n\n![fuel gauge](https://cdn.example.com/a.png)\n\nMore text.\n",
			want: "Intro.\n\nMore text.\n",
			st:   Stats{Images: 1},
		},
		{
			name: "image with a title, an empty alt, an angle destination and parentheses",
			in:   "A\n\n![](https://x/y.png \"Title\")\n\n![a](<https://x/y (1).png>)\n\n![b](https://example.org/wiki/File_(x).png)\n\nB",
			want: "A\n\nB",
			st:   Stats{Images: 3},
		},
		{
			name: "video embedded with image syntax",
			in:   "Text\n\n![Launch replay](https://cdn.example.com/videos/launch-1920x1080.mp4)\n\n## Next\n",
			want: "Text\n\n## Next\n",
			st:   Stats{Videos: 1},
		},
		{
			name: "image in the middle of a sentence keeps its alt",
			in:   "Press the ![Launch](https://x/launch.png) button.",
			want: "Press the Launch button.",
			st:   Stats{Images: 1},
		},
		{
			name: "a video in a sentence never keeps its alt",
			in:   "Watch ![clip](https://x/clip.mp4) and ![the countdown](https://x/countdown.webm) here.",
			want: "Watch and here.",
			st:   Stats{Videos: 2},
		},
		{
			name: "placeholder alt in a sentence goes",
			in:   "See ![image](https://x/a.png) here, and ![ROCKET_IMG](https://x/b.png).",
			want: "See here, and.",
			st:   Stats{Images: 2},
		},
		{
			name: "alt that is a sentence stays on its own line",
			in:   "![The probe sends one reading every second.](https://x/a.png)\n\nNext.",
			want: "The probe sends one reading every second.\n\nNext.",
			st:   Stats{Images: 1},
		},
		{
			name: "alt sentence about the picture goes",
			in:   "A\n\n![A diagram of the probe talking to the ground station.](https://x/a.png)\n\nB",
			want: "A\n\nB",
			st:   Stats{Images: 1},
		},
		{
			name: "html img on its own line and in a sentence",
			in:   "<img src=\"logo.png\" alt=\"Apogee logo\" />\n\nClick <img src='gear.png' alt='the gear'> to open settings.",
			want: "Click the gear to open settings.",
			st:   Stats{Images: 2},
		},
		{
			name: "img with > inside an attribute",
			in:   "A <img alt=\"a > b\" src=\"x.png\"> B",
			want: "A a > b B",
			st:   Stats{Images: 1},
		},
		{
			name: "linked badge image goes with its link",
			in:   "[![CI](https://github.com/o/r/actions/workflows/ci.yml/badge.svg)](https://github.com/o/r/actions)\n\nText",
			want: "Text",
			st:   Stats{Images: 1},
		},
		{
			name: "video iframe over several lines",
			in:   "Watch:\n\n<iframe\n  width=\"560\" src=\"https://www.youtube.com/embed/abc\"\n  allowfullscreen\n></iframe>\n\nAfter.\n",
			want: "Watch:\n\nAfter.\n",
			st:   Stats{Videos: 1},
		},
		{
			name: "video, audio, embed and object elements",
			in:   "A\n\n<video controls src=\"a.mp4\"><source src=\"a.webm\" type=\"video/webm\">Your browser cannot play this.</video>\n\n<audio src=\"a.mp3\"></audio>\n\n<embed src=\"a.swf\">\n\n<object data=\"a.mp4\"><param name=\"x\"></object>\n\nB",
			want: "A\n\nB",
			st:   Stats{Videos: 4},
		},
		{
			name: "picture and inline svg",
			in:   "A\n\n<picture>\n  <source srcset=\"a.webp\">\n  <img src=\"a.png\" alt=\"x\">\n</picture>\n\n<svg viewBox=\"0 0 10 10\"><circle r=\"4\"/></svg>\n\nB",
			want: "A\n\nB",
			st:   Stats{Images: 2},
		},
		{
			name: "figure keeps its caption text",
			in:   "<figure><img src=\"a.png\" alt=\"\"><figcaption>The probe weighs 40 kilograms.</figcaption></figure>",
			want: "<figure><figcaption>The probe weighs 40 kilograms.</figcaption></figure>",
			st:   Stats{Images: 1},
		},
		{
			name: "links to video players become their text",
			in:   "The countdown uses [orbit math](https://www.youtube.com/watch?v=abc123):\n\nRemember to [name your constants](https://www.youtube.com/shorts/def456) and [see this](https://youtu.be/abc), [this](https://vimeo.com/123456) or [that](https://www.loom.com/share/0f1e).",
			want: "The countdown uses orbit math:\n\nRemember to name your constants and see this, this or that.",
			st:   Stats{Links: 5},
		},
		{
			name: "link to a video file becomes its text",
			in:   "Download [the clip](https://x.example/clip.MP4?dl=1) first.",
			want: "Download the clip first.",
			st:   Stats{Links: 1},
		},
		{
			name: "video link alone on its line goes",
			in:   "Intro\n\n[Watch the launch](https://youtu.be/abc)\n\n- [Part 2](https://www.youtube.com/watch?v=def)\n- [Notes](https://go.dev/doc/)\n",
			want: "Intro\n\n- [Notes](https://go.dev/doc/)\n",
			st:   Stats{Links: 2},
		},
		{
			name: "html link to a video",
			in:   "See <a href=\"https://www.youtube.com/watch?v=x\">the talk</a> now.",
			want: "See the talk now.",
			st:   Stats{Links: 1},
		},
		{
			name: "bare and angle links to videos",
			in:   "Video: https://youtu.be/abc\n\n<https://vimeo.com/123>\n\nDocs: https://go.dev/doc/ stays.",
			want: "Video:\n\nDocs: https://go.dev/doc/ stays.",
			st:   Stats{Links: 2},
		},
		{
			name: "reference-style image and its definition",
			in:   "Text\n\n![orbit diagram][d]\n\nMore, see [the docs][docs].\n\n[d]: https://x/d.png\n[docs]: https://go.dev/doc/\n",
			want: "Text\n\nMore, see [the docs][docs].\n\n[docs]: https://go.dev/doc/\n",
			st:   Stats{Images: 1},
		},
		{
			name: "reference-style video link",
			in:   "Watch [the talk][t] first.\n\n[t]: https://www.youtube.com/watch?v=x\n",
			want: "Watch the talk first.\n",
			st:   Stats{Links: 1},
		},
		{
			name: "image in a list item and in a callout",
			in:   "- ![x](https://x/y.png)\n- Real item\n\n> [!tip]\n> ![rocket](https://x/r.png)\n> Keep this.\n",
			want: "- Real item\n\n> [!tip]\n> Keep this.\n",
			st:   Stats{Images: 2},
		},
		{
			name: "image at the very start and the very end",
			in:   "![rocket on the pad](https://cdn.example.com/pad.jpg)\n\n# Learn Launches\n\nText.\n\n![bye](https://x/b.png)",
			want: "# Learn Launches\n\nText.",
			st:   Stats{Images: 2},
		},
		{
			name: "text that refers to a removed picture stays",
			in:   "## Fuel Use\n\n![fuel use](https://cdn.example.com/fuel.png)\n\nIn the chart above, the second stage burns the most fuel.\n",
			want: "## Fuel Use\n\nIn the chart above, the second stage burns the most fuel.\n",
			st:   Stats{Images: 1},
		},
		{
			name: "a widget between paragraphs goes, the prose that mentions it stays",
			in:   "Try the fuel gauge widget below.\n\n```widget fuel-gauge\n{\n  \"tank\": 100,\n  \"burn\": { \"start\": 0, \"stop\": 30 }\n}\n```\n\n## Your Task\n\nWrite it.\n",
			want: "Try the fuel gauge widget below.\n\n## Your Task\n\nWrite it.\n",
			st:   Stats{Widgets: 1},
		},
		{
			name: "widgets fenced with tildes and longer fences, first and last",
			in:   "~~~widget star-map\n{\"stars\": 12}\n~~~\n\nMiddle.\n\n````widget orbit-plotter\n{\"orbit\": \"low\"}\n````\n",
			want: "Middle.\n",
			st:   Stats{Widgets: 2},
		},
		{
			name: "a widget right between two lines keeps them apart",
			in:   "First paragraph.\n```widget thrust-curve\n{\"engines\": 6}\n```\nSecond paragraph.",
			want: "First paragraph.\n\nSecond paragraph.",
			st:   Stats{Widgets: 1},
		},
		{
			name: "a widget in a quote",
			in:   "> Text.\n>\n> ```widget star-map\n> {\"stars\": 3}\n> ```\n>\n> More.\n",
			want: "> Text.\n>\n> More.\n",
			st:   Stats{Widgets: 1},
		},
		{
			name: "an unclosed widget fence runs to the end",
			in:   "Text.\n\n```widget star-map\n{\"stars\": 3}\n",
			want: "Text.\n",
			st:   Stats{Widgets: 1},
		},
		{
			name: "plain links, links to pictures and channels stay",
			in:   "[Go docs](https://go.dev/doc/), [the PNG spec](https://x/spec.png), [the Apogee channel](https://www.youtube.com/@ApogeeLaunches), \\![not an image](x.png)",
			want: "[Go docs](https://go.dev/doc/), [the PNG spec](https://x/spec.png), [the Apogee channel](https://www.youtube.com/@ApogeeLaunches), \\![not an image](x.png)",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, st := Strip(tc.in)
			if got != tc.want {
				t.Errorf("got\n%q\nwant\n%q", got, tc.want)
			}
			if st != tc.st {
				t.Errorf("stats = %+v, want %+v", st, tc.st)
			}
		})
	}
}

// Lessons teach HTML and Markdown: media syntax inside code must stay exactly as it is.
func TestStripMediaLeavesCode(t *testing.T) {
	for _, in := range []string{
		"```html\n<html>\n  <body>\n    <h1>Mission Control</h1>\n    <img src=\"/rocket.png\" alt=\"Apogee rocket\" />\n  </body>\n</html>\n```\n",
		"```md\n![a rocket](ROCKET_URL)\n```\n",
		"1. [ ] Download the replay:\n\n   ```sh\n   curl -o assets/replay.mp4 https://cdn.example.com/videos/replay.mp4\n   ```\n",
		"> ```html\n> <iframe src=\"/telemetry-panel.html\" sandbox=\"allow-scripts\"></iframe>\n> ```\n",
		"Use the `<video>` element, and `![x](y.png)`, and ``<img src=\"a`b.png\">``.\n",
		"Indented code:\n\n    page := `<html><body><img src=\"/pad.png\" alt=\"Pad 39\"></body></html>`\n",
		"<pre>\n<img src=\"a.png\">\n</pre>\n",
		"```go\nfunc main() {}\n```\n",
		"```sh\necho widget\n```\n",
		"```json\n{\"widget\": \"fuel-gauge\", \"tank\": 100}\n```\n",
		"```widgets\n{\"not\": \"a widget fence\"}\n```\n",
		"````md\nA widget fence looks like this:\n\n```widget star-map\n{\"stars\": 3}\n```\n````\n",
		"The widget above shows how the tank drains.\n",
	} {
		got, st := Strip(in)
		if got != in || st.Total() != 0 {
			t.Errorf("code was changed:\n%q\nbecame\n%q (%+v)", in, got, st)
		}
	}

	in := "Before ![pic](https://x/p.png) the code:\n\n```go\n// ![keep](me.png)\nfmt.Println(\"<img src=x>\")\n```\n\nand `<iframe>` after <iframe src=\"https://www.youtube.com/embed/x\"></iframe>\n"
	want := "Before the code:\n\n```go\n// ![keep](me.png)\nfmt.Println(\"<img src=x>\")\n```\n\nand `<iframe>` after\n"
	if got, _ := Strip(in); got != want {
		t.Errorf("mixed text and code:\ngot  %q\nwant %q", got, want)
	}
}

func TestStripMediaLeavesPlainText(t *testing.T) {
	for _, in := range []string{
		"",
		"Plain text with no media.",
		"On a site like YouTube, the launch replay sits next to the comments.",
		"- [ ] task\n- [x] done\n\n> [!warning]\n> Careful.\n",
		"| a | b |\n|---|---|\n| 1 | 2 |\n",
		"Tests expect `launch-replay.mp4` in the listing.",
	} {
		if got, st := Strip(in); got != in || st.Total() != 0 {
			t.Errorf("Strip(%q) = %q, %+v", in, got, st)
		}
	}
}

func TestIsVideoURL(t *testing.T) {
	for u, want := range map[string]bool{
		"https://cdn.example.com/videos/intro-1920x1080.mp4":       true,
		"https://example.com/clip.MOV?x=1":                         true,
		"https://example.com/stream/index.m3u8":                    true,
		"https://www.youtube.com/watch?v=abc123&ab_channel=Apogee": true,
		"https://m.youtube.com/watch?v=x":                          true,
		"https://youtube.com/shorts/def456":                        true,
		"https://www.youtube.com/embed/abc":                        true,
		"https://www.youtube-nocookie.com/embed/abc":               true,
		"https://youtu.be/abc":                                     true,
		"https://vimeo.com/123456":                                 true,
		"https://player.vimeo.com/video/123":                       true,
		"https://www.loom.com/share/abc":                           true,
		"https://www.twitch.tv/videos/1":                           true,
		"<https://youtu.be/abc>":                                   true,
		"https://www.youtube.com/@ApogeeLaunches":                  false,
		"https://www.youtube.com/":                                 false,
		"https://vimeo.com/about":                                  false,
		"https://www.twitch.tv/apogee":                             false,
		"https://cdn.example.com/diagram.png":                      false,
		"https://example.com/video-guide":                          false,
		"assets/replay.mp4":                                        true,
		"":                                                         false,
	} {
		if got := isVideoURL(u); got != want {
			t.Errorf("isVideoURL(%q) = %v, want %v", u, got, want)
		}
	}
}

func TestAltReadsAsContent(t *testing.T) {
	for _, tc := range []struct {
		alt        string
		inSentence bool
		want       bool
	}{
		{"fuel gauge", false, false},
		{"An xkcd about rocket launches.", false, false},
		{"Launch explainer video", false, false},
		{"alt text", false, false},
		{"Alt-text goes here", true, false},
		{"ROCKET_IMG", true, false},
		{"pad-39.png", true, false},
		{"", true, false},
		{"Launch", true, true},
		{"the gear", true, true},
		{"The probe sends one reading every second.", false, true},
		{"A screenshot of the mission console.", false, false},
		{"Three words only.", false, false},
	} {
		if got := altReadsAsContent(tc.alt, tc.inSentence); got != tc.want {
			t.Errorf("altReadsAsContent(%q, %v) = %v, want %v", tc.alt, tc.inSentence, got, tc.want)
		}
	}
}

func TestCodeSpansCoverCode(t *testing.T) {
	md := "a `b` c\n\n```go\nx\n```\n"
	code := codeSpans(md)
	for i, c := range md {
		inCode := code.contains(i)
		switch {
		case c == 'b' || c == 'x':
			if !inCode {
				t.Errorf("%q at %d is code", c, i)
			}
		case c == 'a' || c == 'c':
			if inCode {
				t.Errorf("%q at %d is not code", c, i)
			}
		}
	}
	if !strings.Contains(md, "```") {
		t.Fatal("bad fixture")
	}
}
