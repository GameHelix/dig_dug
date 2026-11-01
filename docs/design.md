# Design

Gopherwood should look and feel like an app Apple would ship: native controls, Liquid Glass,
calm typography, and every action on the keyboard. Nothing in it looks like a web page.

## Platform

- macOS 27 or later, the current release, so the app is Liquid Glass throughout. The standard containers get it
  from the system: the split view's sidebar, the unified toolbar, sheets, menus and the
  inspector. Custom surfaces use `glassEffect` inside a `GlassEffectContainer`: the run
  status bar, quiz answers and command-line steps. There is no hand-made blur, gradient or
  shadow.
- Light, dark, Increase Contrast and Reduce Motion all look right.
- Colors are semantic: `.primary`, `.secondary`, `.tint` and system backgrounds. The one
  accent is Go Blue, #00ADD8 in dark mode and Go Teal #00758D in light mode for contrast,
  set as the asset's AccentColor.
- Icons are SF Symbols with hierarchical rendering. State changes use symbol effects:
  `.bounce` on success, `.replace` between Run and Stop.

## Window

- One main window, at least 1100×700. It remembers its size, the sidebar width, every split
  and the last lesson.
- `NavigationSplitView` with the sidebar and the lesson. The toolbar:
  - back and forward through the lessons you visited;
  - the lesson's title, with course › chapter as the subtitle;
  - Run ⌘R, and Submit ⌘↩ as the prominent glass button;
  - the search field;
  - the inspector toggle.
- The inspector on the right holds your note for the lesson (autosaved) and the lesson's
  facts: type, difficulty, and topics as tags.

## Sidebar

- One section per course, with its title and a progress ring for finished lessons out of
  required ones. Guided projects sit under their own heading.
- Chapters are disclosure groups; the current one is open.
- Each lesson row shows a type symbol, the title, and a done mark (`checkmark.circle.fill`
  in the tint). The type symbols:
  - code: `chevron.left.forwardslash.chevron.right`
  - tests: `checklist`
  - quiz: `questionmark.bubble`
  - command line: `terminal`
  - GitHub: `arrow.triangle.branch`
  - interview: `person.wave.2`
- Search runs through the full-text index and lists matching lessons, with the match
  highlighted.

## Reading

- The readme column is about 72 characters wide (about 680 pt), centered in its pane. Body
  text is SF Pro 15 pt with a 1.45 line height, and paragraphs are 12 pt apart. Headings
  are 28, 22, 18 and 15 pt semibold. All text is selectable.
- Code blocks are SF Mono 13 pt on a 10 pt rounded `.quaternary` panel, with a language
  label and a Copy button on hover. Go is highlighted in Xcode's default light and dark
  palettes.
- Callouts ([!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION]) are tinted rounded
  panels with their symbol.
- Tables have hairline rules and zebra rows. Inline code sits in a subtle capsule. Links
  open in the default browser.

## Lessons

- **Code**:
  - Readme on the left. On the right, the editor above the console.
  - The editor is SF Mono 13 pt (size in Settings), with a quiet line-number gutter, a
    current-line highlight, tabs four wide, highlighting and the find bar.
  - The editor's file bar holds the file picker and, at its trailing end, a compact group of
    borderless buttons: Format (`wand.and.stars`), Toggle Comment (`//` in SF Mono), Outdent
    (`decrease.indent`) and Indent (`increase.indent`). Each button's help names it and its
    shortcut, or says why it can't act: another kind of file, a read-only file, code still
    loading, or no Go. The Editor menu has them too: Format Code ⇧⌥F, Toggle Comment ⌘/,
    Indent ⌥⌘] and Outdent ⌥⌘[.
  - Format runs gofmt on the file as one undo step, and the caret keeps its line and column.
    Code that does not parse stays as it is, and gofmt's messages show in the console, titled
    Format, with the file's name.
  - Toggle Comment, Indent and Outdent act on the selected lines, or the caret's line, as one
    undo step, and the same lines stay selected. Tab and ⇧Tab indent and outdent selected
    lines too.
  - The console opens with a glass status bar: state symbol, duration, passed or failed.
    The output below it is monospaced, and the first failing test is expanded.
  - "Reset to Starter Code" asks first.
- **Quiz**:
  - Each question is a card, and its answers are large selectable rows. Keys 1 to 5 pick an
    answer.
  - After Submit the right answer turns green with a checkmark. A wrong pick turns red, and
    the right one is shown.
  - Success gives a light trackpad haptic (NSHapticFeedbackManager) and the done mark
    bounces.
- **Command line**:
  - A pipeline of steps. Each step shows a state (pending, running, passed, failed), its
    command or `METHOD url`, and a detail that opens to show output, the response's status,
    headers and body, and each test passed or failed.
  - The project folder and server address sit at the top and can be edited.
- **GitHub and interview**: the readme, the checks as a reference checklist, and a clear
  Mark as Done button.
- After a pass, Next Lesson (⌘]) appears in the toolbar.

## States

- Use `ContentUnavailableView` when no library is open (with Open Library…), a library is
  refused (naming the problems), nothing is selected, a search finds nothing, or Go is
  missing (with a button to Settings).
- Errors appear as an inline banner or an alert with a clear action. They are never silent.
- Long work shows progress in place, never a frozen window.

## Settings

A standard Settings window with grouped forms:
- General: the repository folder.
- Editor: font size, line numbers.
- Go: toolchain path and the detected version.
- Sync: commit and push automatically, and the last push.

## Icon

A layered macOS 27 rounded-square icon: a simple gopher-and-tree mark in Go Blue on deep
green, sharp at every size from 16 to 1024 px, delivered as `AppIcon.icns`.

## Accessibility

- Every control has a VoiceOver label.
- The whole app works from the keyboard: Tab, arrow keys in the sidebar, and the shortcuts
  above.
- Hit targets are at least 24 pt.
