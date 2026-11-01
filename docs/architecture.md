# Architecture

Gopherwood is a native macOS app (SwiftUI, with AppKit where SwiftUI falls short) that opens
any **library**: one SQLite file in the format of `docs/library-format.md`, holding a
syllabus and the learner's data. Nothing in the app depends on a particular library. Go tools
create, check and fill libraries. This repository's library, `data/gopherwood.sqlite`, is
committed as the file itself. Everything lives in this one repository.

## Repository

| Path | What it is |
|---|---|
| `data/gopherwood.sqlite` | This repository's library: lessons and all your study data |
| `db/schema.sql` | The schema (version in `user_version`); `db/` also holds the Go package that creates, opens and checks the database, with the schema embedded |
| `cmd/library/` | The library tool, for any library: `create`, `check`, `migrate` |
| `cmd/author/`, `internal/` | The authoring tool: writes lessons into a library from lesson packages and exports them back; `internal/store` writes a lesson's rows, `internal/media` refuses pictures, videos and embeds |
| `app/` | The Swift package: `GopherwoodKit` (library) and `Gopherwood` (the app) |
| `app/Packages/` | The app's own packages: `JQ` (jq compiled in), `LessonHTTP` (the HTTP client for lesson checks) and `CodeEditor` (the editor, plus `SyntaxCore`) |
| `docs/library-format.md` | The library format: what a library holds and what the app checks on open |
| `Makefile` | `make app`, `make install`, `make test`, `make check` |

## The database

- The `db` package owns the format: the schema, the checks and the migrations, used by
  `cmd/library` and `cmd/author`. A content producer (here `cmd/author`) is the only writer of
  lesson tables.
- The app opens any library that passes the checks in `docs/library-format.md`: File ›
  Open Library…, recent libraries, and the current one remembered. It reads the lesson
  tables and writes only the learner's tables: progress, attempt, note, code_file, project,
  server_address and setting. It never creates or migrates a library; `cmd/library migrate`
  does, with the migrations in `db/migrate.go`.
- Every connection turns on foreign keys and keeps the rollback journal (no WAL), so the
  committed file is always whole. Timestamps are ISO 8601 in UTC with a trailing Z.
- Settings that belong to one Mac, like which library is open and window frames, live in
  UserDefaults. Everything that should follow you to another Mac lives in the library.

## The app

Swift 6.4 (swift-tools-version 6.4) in the Swift 6 language mode with complete concurrency
checking; macOS 27 or later, the current release, with Liquid Glass (see `docs/design.md`
for how it looks). It builds with
SwiftPM and the Command Line Tools, no Xcode needed. `make app` assembles
`build/Gopherwood.app` (Info.plist, icon, ad-hoc signature); the package also opens in Xcode
as is.

**GopherwoodKit** imports neither SwiftUI nor AppKit. It holds the models and services and is
covered by Swift Testing tests.

- **AppDatabase**: one GRDB `DatabaseQueue` (a `DatabasePool` would need WAL). It validates
  the file on open and serves typed reads, such as the catalog with your progress, full-text
  search, and a lesson's content as one enum case per lesson type built from its tables.
  It also does the writes to your tables. The UI follows changes through `ValueObservation`.
- **Readme**: Apple's swift-markdown parses the Markdown. A visitor turns the tree into the
  render model, including `[!NOTE]`-style callouts and OS-tagged headings. Images and
  videos are never rendered.
- **Go syntax**: a lexer that follows the Go specification and turns code into highlight
  ranges. Readme code blocks and the editor both use it.
- **Process running**:
  - Programs start from a resolved path with an argument array, never a shell string,
    except for a lesson's own command line, which runs under `/bin/zsh -c`.
  - Each run gets an explicit environment and working folder.
  - stdout and stderr are read concurrently.
  - Each run starts in its own process group. A timeout or a cancelled task kills the
    whole group.
  - A run can be given standard input, which is written while the output is read.
- **Go toolchain**: `go` comes from the path set in Settings, else from the login shell's
  PATH, else from the usual install locations. gofmt is the one in that Go's GOROOT.
- **Code runs**: your code_file rows are written to
  `~/Library/Caches/Gopherwood/work/<lesson>/`. `go run` or `go test` runs there, and the
  output is compared or the tests are read.
- **Formatting**: gofmt reads the file on standard input and writes it back on standard
  output, so nothing is written to the work folder.
- **Command-line checks**:
  - Steps run in order in the course's project folder, with captured `${names}` passed on
    to later steps.
  - HTTP requests go through the app's own HTTP/1.1 client on SwiftNIO over
    Network.framework (NIOTransportServices). Each request goes out exactly as the step
    defines it, with no added cookies, cache or headers. Redirects are followed only when
    the step allows it, and response trailers are read, which URLSession cannot do.
  - jq programs, both tests and JSON-path captures, run in process on jq 1.8.2. It is
    compiled into the app from its C sources, with Oniguruma for regular expressions,
    because the lessons use the real language (`scan`, `any`, `all`, slices).
- **GitSync**: an actor that runs `/usr/bin/git -C <work tree>`, used only when the open
  library sits inside a git work tree (`rev-parse --show-toplevel`). Elsewhere sync is off
  and changes stay on the Mac.
  - Before a library opens it runs `pull --ff-only`. Any later pull closes the database
    first.
  - `commit --only <the library's path>` and `push` run while no write is in progress.
    They happen after you finish a lesson, after ten minutes of changes, and on quit.
  - A conflict is reported, never merged.

**Gopherwood** is the SwiftUI app.

- `@main` App with a single main window. It is a `NavigationSplitView`: the sidebar holds
  courses, chapters and lessons with done marks and search, and the detail shows the lesson
  in a view made for its type.
- A Settings scene, and menu commands: Run ⌘R, Submit ⌘↩, Next ⌘], Previous ⌘[, and in the
  Editor menu Format Code ⇧⌥F, Toggle Comment ⌘/, Indent ⌥⌘] and Outdent ⌥⌘[.
- State lives in `@Observable @MainActor` models that get their services through the
  environment. Views stay thin, and there are no singletons.
- The code editor is an `NSTextView` (TextKit 2) behind `NSViewRepresentable`. It is
  monospaced, keeps tabs, and has line numbers, undo, find and highlighting. It saves to
  code_file after a second of idle typing. A `CodeEditorProxy` lets the Editor menu and the
  editor bar edit it: each command, and gofmt's output, is one undo step.
- Errors are typed and shown to you, never swallowed. Logging uses `os.Logger`.

## Self-contained, fast, reliable

- **Self-contained**: the app is one process, and its bundle holds everything it runs: the
  database layer, Markdown, highlighting, jq and the HTTP client. Outside it, the app uses
  only what a Mac for learning Go has anyway:
  - the Go toolchain, to run your code (the app finds it, or tells you how to install it);
  - `/bin/zsh`, for a lesson's own command lines;
  - `/usr/bin/git`, to sync the database.
- **Fast**: these budgets are measured with `os_signpost` intervals and tested where they
  can be.
  - The window is usable less than a second after launch.
  - Switching lessons takes under 100 ms.
  - Search results arrive in under 50 ms while you type.
  - No work on the main thread takes longer than a frame.
- **Reliable**:
  - No force unwraps, `try!` or `fatalError` except for programmer errors.
  - Every failure is a typed error that you see.
  - Database writes happen in transactions, and `PRAGMA quick_check` runs on open.
  - Every outside process can be cancelled and has a timeout.
  - The window and your place are restored on relaunch.

## Dependencies

Everything is kept at its latest release and pinned by `app/Package.resolved` and `go.sum`,
both committed. These were the latest on 2026-10-31:

| Part | Version |
|---|---|
| Toolchain | Command Line Tools 27.2 (Swift 6.4.2) and Go 1.27.3 |
| App | GRDB.swift 7.11.1, swift-markdown 0.9.0, SwiftNIO 2.104.0, swift-nio-transport-services 1.28.0 |
| App, compiled in | jq 1.8.2 and Oniguruma 6.9.10, vendored as C targets by `app/Packages/JQ/scripts/vendor.sh` from the release tarballs, with SHA-256 checked; one line is changed so jq never reads `~/.jq` |
| Library tools | modernc.org/sqlite v1.61.1 (with modernc.org/libc held at the exact v1.79.0 its go.mod requires), goldmark v1.8.7 |

A new dependency needs a reason written here.

## Tests

`make test` runs `go test ./...` and `swift test`. Tests build their own database from
`db/schema.sql` with fixture lessons of every type. No test touches `data/gopherwood.sqlite`
or this repository's git; git tests use a throwaway repository and bare remote in `$TMPDIR`.
