# Architecture

Gopherwood is a native macOS app (SwiftUI, with AppKit where SwiftUI falls short) and a Go
tool that fills its lessons. Both work on one SQLite database, `data/gopherwood.sqlite`,
committed to this repository as the file itself. Everything lives in this one repository.

## Repository

| Path | What it is |
|---|---|
| `data/gopherwood.sqlite` | The database: lessons and all your study data |
| `db/schema.sql` | The schema (version in `user_version`); `db/` also holds the Go package that creates, opens and checks the database, with the schema embedded |
| `cmd/sync/`, `internal/` | The sync tool, in Go: boot.dev client, lesson mapping, image and video stripping, checks |
| `app/` | The Swift package: `GopherwoodKit` (library) and `Gopherwood` (the app) |
| `Makefile` | `make app`, `make install`, `make test`, `make sync` |

## The database

- The sync tool owns the schema and the lesson tables: it creates the file from
  `db/schema.sql`, migrates it, and is the only writer of lesson tables.
- The app reads lesson tables and writes only your tables: progress, attempt, note,
  code_file, project and setting. It opens a file only when `application_id` is
  1196447556 and `user_version` is the version it was built for. It never creates or
  migrates one.
- Every connection turns on foreign keys and keeps the rollback journal (no WAL), so the
  committed file is always whole. Timestamps are ISO 8601 in UTC with a trailing Z.
- Settings that belong to one Mac, like where this repository is and window frames, live in
  UserDefaults. Everything that should follow you to another Mac lives in the database.

## The app

Swift 6 language mode with complete concurrency checking; macOS 26 or later, for Liquid Glass
(see `docs/design.md` for how it looks). It builds with
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
  render model, including boot.dev's `[!NOTE]` callouts and OS-tagged headings. Images and
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
- **Go toolchain**: `go` comes from the path set in Settings, else from the login shell's
  PATH, else from the usual install locations.
- **Code runs**: your code_file rows are written to
  `~/Library/Caches/Gopherwood/work/<lesson>/`. `go run` or `go test` runs there, and the
  output is compared or the tests are read.
- **Command-line checks**:
  - Steps run in order in the course's project folder, with captured `${names}` passed on
    to later steps.
  - HTTP requests go through an `HTTPTransport` protocol. The URLSession transport uses an
    ephemeral session with no cookie storage or automatic cookies and no cache, and follows
    redirects only when the step allows it.
  - URLSession cannot read HTTP trailers, so a step that tests trailers is sent with the
    curl transport.
  - jq expressions, both tests and JSON-path captures, run through `/usr/bin/jq`. There is
    only one jq implementation.
- **GitSync**: an actor that runs `/usr/bin/git -C <repo>`.
  - At launch it runs `pull --ff-only` before the database opens. Any later pull closes
    the database first.
  - `commit --only data/gopherwood.sqlite` and `push` run while no write is in progress.
    They happen after you finish a lesson, after ten minutes of changes, and on quit.
  - A conflict is reported, never merged.

**Gopherwood** is the SwiftUI app.

- `@main` App with a single main window. It is a `NavigationSplitView`: the sidebar holds
  courses, chapters and lessons with done marks and search, and the detail shows the lesson
  in a view made for its type.
- A Settings scene, and menu commands: Run ⌘R, Submit ⌘↩, Next ⌘], Previous ⌘[.
- State lives in `@Observable @MainActor` models that get their services through the
  environment. Views stay thin, and there are no singletons.
- The code editor is an `NSTextView` (TextKit 2) behind `NSViewRepresentable`. It is
  monospaced, keeps tabs, and has line numbers, undo, find and highlighting. It saves to
  code_file after a second of idle typing.
- Errors are typed and shown to you, never swallowed. Logging uses `os.Logger`.

## The sync tool

- Go module `github.com/jobloom/gopherwood`. `cmd/sync` is the command.
- `internal/bootdev` is the client: polite delays, retries with backoff on 429 and 5xx,
  `context` timeouts.
- `internal/lessons` maps a lesson to rows and validates it. `internal/media` strips images
  and video embeds.
- `db` holds the embedded schema, plus `Open`, `Create` and the integrity checks.
- Writes:
  - Lessons are upserted by uuid, never replaced or deleted.
  - Each changed lesson is rewritten in one transaction.
  - After every run the checks must pass.
  - `VACUUM` runs only after a full rebuild, since it rewrites every page and bloats git
    history.

## Dependencies

Pinned by `app/Package.resolved` and `go.sum`, both committed: GRDB.swift and
swift-markdown for the app; modernc.org/sqlite and goldmark for the sync tool. A new
dependency needs a reason written here.

## Tests

`make test` runs `go test ./...` and `swift test`. Tests build their own database from
`db/schema.sql` with fixture lessons of every type. No test touches `data/gopherwood.sqlite`
or this repository's git; git tests use a throwaway repository and bare remote in `$TMPDIR`.
