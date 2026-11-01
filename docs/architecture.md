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
| `app/Sources/GopherwoodKit/GitHub/` | GitHub: the API client, the GitHub CLI's sign-in, the GitHub lesson checker, and your solutions repository |
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
  UserDefaults. Everything that should follow you to another Mac lives in the library. A
  course's repository on GitHub, which its GitHub lessons check, is the library's
  (project.github_repo); your solutions repository and its folder are this Mac's.

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
- **GitHub** (`GitHub/`), through `URLSession` to api.github.com, REST API version
  2022-11-28, with 20 s request and 90 s overall timeouts and no cookies, cache or stored
  credentials:
  - The sign-in is the GitHub CLI's. `gh` is found as `go` is: the login shell's PATH, then
    /opt/homebrew/bin and /usr/local/bin. `gh auth token` runs through the process runner
    only when the app checks GitHub (a lesson's Check, Settings, a solutions repository
    being set up or pushed). The token lives for that check: it is never stored, logged or
    shown (`GitHubToken` prints and reflects as hidden).
  - The token goes to api.github.com over https only. The client follows redirects itself
    (URLSession is told not to), so a log download, redirected to blob storage, goes out
    without it.
  - Every request is a GET, except one: POST /user/repos when you click Create Repository….
  - Without gh, or signed out, requests are anonymous: public repositories only, and no
    workflow logs. A used-up rate limit (403 or 429 with X-RateLimit-Remaining 0), a
    secondary limit, a refused token, a 5xx or no network stop a check run with a message.
- **GitHub lessons** (`GitHubChecker`): each step against the course's repository. The
  repository, the latest run of a workflow and a run's jobs are asked for once per run.
  - repo_exists and submit_repo_for_course: GET /repos/{o}/{r} is 200.
  - branch_exists: GET /repos/{o}/{r}/branches/{branch}, the name percent-encoded.
  - file_contains: GET /repos/{o}/{r}/contents/{path} on the default branch, base64-decoded,
    holds every text.
  - pr_exists: GET /repos/{base}/pulls?state=all&head={owner}:{compare}&base={branch} finds
    one, in your repository unless the step names another. Query values are percent-encoded
    with + & = # and ? too, so a branch such as c++ stays one value.
  - workflow_status: the newest run of the workflow (its file, such as ci.yml, else the name
    its file declares), on any branch, ended in the conclusion the step wants; a run not
    finished says so.
  - workflow_logs_contains: in that run, each job's log (GET /actions/jobs/{id}/logs) holds
    its texts.
  - A run ends in an attempt of kind check, as command-line checks do, and all passed
    finishes the lesson.
- **Solutions** (`SolutionsRepository`, an actor like GitSync): your repository on GitHub
  with a folder of its own on this Mac, never inside ~/Documents/jobloom or the library's
  repository.
  - Create Repository… makes it with POST /user/repos (auto_init false), then `git init -b
    main` in the folder and origin `https://github.com/<owner>/<name>.git`. Use Existing
    Repository… clones it, or takes a folder that already is a clone of it.
  - A passing Submit of a Go code lesson writes your editable files to
    `<course slug>/<NN>-<chapter slug>/<NN>-<lesson slug>/`, rewrites the table of solved
    lessons per course, with the day each was first committed, and commits both with
    `git commit --only`, as `Solve "<lesson>" (<course>)`, with GIT_AUTHOR_DATE and
    GIT_COMMITTER_DATE at the Submit. Code that is as the last commit has it makes no commit.
  - The table is README.md when there is none or Gopherwood wrote it (its first line is
    `<!-- Written by Gopherwood: the solved lessons. -->`); a README of your own stays as it
    is, and the table goes in SOLUTIONS.md. Use Existing Repository… says which.
  - The author is git's user.name and user.email; failing those, your GitHub login and
    noreply address (`<id>+<login>@users.noreply.github.com`, from GET /user, kept for
    working offline), so the commits count on your contribution graph.
  - Committing is local. Pushing is `git -c credential.helper= -c
    'credential.helper=!<gh> auth git-credential' push origin HEAD`: gh hands git the token
    on a pipe, never in a URL, a config file or an argument. It runs after each passing
    Submit only when you turn that on, and from File › Push Solutions to GitHub. A push asked
    for while one runs pushes again when it ends. A push that fails keeps every commit for
    the next. How each push went (pushed N, nothing to push, or why not) shows in the quiet
    git line under the sidebar, as the library's sync does, so Settings needn't be open.
  - Only commits on the default branch count on the contribution graph: on another branch,
    Settings says so in place (the default is origin's HEAD, else main).
  - Add N Earlier Solutions commits the done lessons with saved code the repository lacks,
    oldest first, each dated at its done_at. What the repository holds is what its last
    commit holds (`ls-tree HEAD`), so a lesson whose commit failed is offered again.
  - With HEAD detached (a commit checked out, a rebase under way) nothing is committed or
    pushed, and you are told to switch back to a branch.
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
- A Settings scene, and menu commands: Run ⌘R, Submit ⌘↩ (Check in a GitHub lesson), Next ⌘],
  Previous ⌘[, File › Push Solutions to GitHub, and in the Editor menu Format Code ⇧⌥F,
  Toggle Comment ⌘/, Indent ⌥⌘] and Outdent ⌥⌘[.
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
  - `/usr/bin/git`, to sync the database and to keep your solutions repository;
  - the GitHub CLI (`gh`), for your GitHub sign-in, and api.github.com, for GitHub lessons
    and your solutions repository. Without gh the app reads public repositories anonymously.
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
  - One copy of the app runs at a time: a launch while a copy with the same bundle id runs
    (say from ~/Applications and from build/) brings that one forward and quits before it
    opens the library. A copy with another bundle id, such as a QA copy, is not affected.

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
GitHub tests answer from a URLProtocol stub, and solutions tests push to a bare repository
that git's url.insteadOf puts in place of github.com, with git limited to local paths
(GIT_ALLOW_PROTOCOL=file) and a stand-in gh: no test reaches the network or runs the real gh.
A scripted run of the app (launch arguments for screenshots) never creates a repository on
GitHub or pushes to github.com.
