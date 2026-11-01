# Gopherwood, the app

A native macOS app (SwiftUI, with AppKit where SwiftUI falls short) for studying Go courses
offline. It opens a **library**: one SQLite file with courses, their lessons and your progress
in them (`../docs/library-format.md` is the format). Any library works the same. The app checks
your code with your own Go toolchain and keeps your study data in the library file; when the
file sits in a git work tree, it commits and pushes it for you. How it is built is in
`../docs/architecture.md`, how it looks in `../docs/design.md`.

## Build, install, run

From the repository root, with the Command Line Tools (no Xcode needed) on macOS 27:

```sh
make install
```

That builds `build/Gopherwood.app` (release build, Info.plist, icon, ad-hoc signature) and
copies it to `~/Applications`. Open it from Spotlight or Launchpad. `make app` only builds.

The app opens the library its `LibraryPath` setting names. Open another one with File > Open
Library… (⌘O) or File > Open Recent, or in Settings > General. Before any of it is shown, a
library passes the format's checks, the same as `go run ./cmd/library check <file>`; a file
that fails is refused with the problems the checks found.

## Test

```sh
make test                      # go test ./... and swift test
swift test --package-path app  # the app's tests only
```

The tests build their own libraries from `db/schema.sql` in `$TMPDIR`, with made-up lessons;
no test reads a real library. Some run a real `go build` / `go test` and are skipped when Go
is not installed. The git tests use a throwaway repository and bare remote in `$TMPDIR`.

## Where things are

| What | Where |
|---|---|
| Lessons and your study data | The library file (progress, attempts, notes, code, projects, server addresses, settings) |
| Lesson folders for building and running | `~/Library/Caches/Gopherwood/work/<lesson uuid>/`, disposable; each run keeps its build files in `work/.runs` while it lasts |
| Settings for this Mac | UserDefaults `io.github.jobloom.Gopherwood`: the library's path and recent libraries, the Go path, window layout, sync on or off |

Your code lives in the database. To run it, the app writes a lesson's files to its work
folder (your files, the read-only tests, `go.mod`, the readme) and builds there; hidden
helper files are added with `go build -overlay`. Edits you make in another editor (Lesson >
Open Lesson Folder in Editor) are taken in when you come back to the app and before every
save and run. If you changed the same file in the app too, it asks which version to keep.

A tests lesson passes when `go test` passes and the tests report no failed case themselves:
some lesson tests print Fail and a summary such as "0 passed, 5 failed" without failing the
test, so the exit status alone is not enough. A code lesson in another language than Go
opens and can be read and edited, but the console says Gopherwood runs Go lessons.

## Command-line lessons

Commands run in the course's project folder, which you choose once per course. A lesson's
`${baseURL}` is the server address it suggests, or yours for it: an address you enter
replaces that suggestion for every lesson that makes it, and Use Suggested goes back. A
lesson that checks a server you deployed suggests none and asks for your server's address,
which the course keeps.

## Git

When it opens a library, the app asks git whether the file sits in a work tree (`git -C <its
folder> rev-parse --show-toplevel`). If it does, the app runs `git pull --ff-only` before it
opens the file, and closes the file before any later pull. It commits only the library file
(`git commit --only`, which leaves anything else you staged alone) and pushes: after you
finish a lesson, after ten minutes of changes, and when you quit. It never merges; a conflict
or a failed push shows under the sidebar and in Settings > Sync, where sync can also be
turned off. A library outside a work tree stays on this Mac, and Settings > Sync says so.

Git steps run one at a time, and git is never killed outright: a step that takes too long
gets SIGTERM and time to remove its lock file. Quitting waits for a sync under way, then
commits and pushes (at most 20 seconds in all). If `.git/index.lock` is left over while no
git is running, the app says so and offers to remove it.

## Keyboard

| Keys | Action |
|---|---|
| ⌘R | Run (or Run Checks) |
| ⌘↩ | Submit |
| ⌘. | Stop |
| ⇧⌥F | Format the file with gofmt |
| ⌘/ | Comment or uncomment the selected lines |
| ⌥⌘] / ⌥⌘[ | Indent / outdent the selected lines |
| Tab / ⇧Tab | With lines selected: indent / outdent them (⇧Tab also outdents the caret's line) |
| ⌘] / ⌘[ | Next / previous lesson |
| ⌥⌘← / ⌥⌘→ | Back / forward through lessons you visited |
| 1 to 5 | Pick a quiz answer |
| ⇧⌘D | Mark as done |
| ⇧⌘R / ⇧⌘O | Reveal the lesson folder in Finder / open it in your editor |
| ⌥⌘I | Show the inspector (note and lesson facts) |
| ⌘= / ⌘- / ⌘0 | Bigger / smaller / actual-size code |

## Layout

| Path | What it is |
|---|---|
| `Sources/GopherwoodKit` | Models and services, no SwiftUI or AppKit: the database (GRDB), readmes (swift-markdown), the Go lexer, process running, the Go toolchain, code runs, command-line checks, git |
| `Sources/Gopherwood` | The SwiftUI app: models, views, rendering |
| `Tests/GopherwoodKitTests` | Swift Testing tests |
| `Packages/` | Local packages: the HTTP client for checks, jq, the code editor |
| `Resources/` | `Info.plist` and `AppIcon.icns` |
| `scripts/bundle.sh` | Assembles and signs the .app (`make app` runs it) |
| `scripts/make-icon.sh` | Redraws `Resources/AppIcon.icns` from `scripts/make-icon.swift` |

## Scripted runs

Two launch arguments help with screenshots and debugging; they are read from the command line
only and never stored:

```sh
open -n build/Gopherwood.app --args -GopherwoodOpenLesson <lesson uuid> -GopherwoodLaunchAction run
```

The action is one of `run`, `submit`, `check`, `answer` (answers a quiz), `format` (formats the
file shown with gofmt), `footer` (scrolls to the part below the readme), `settings` (opens
Settings), `walk` (opens the next ten lessons) or `search:<text>` (types a search). `-LibraryPath <file>` opens another library for that launch.
