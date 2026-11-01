# Library format

Gopherwood is not tied to any particular course. It opens a **library**: one SQLite file
that holds a syllabus (courses, chapters, lessons) and the learner's own data for it. Any
file in this format plugs in, and the app behaves the same with it. `data/gopherwood.sqlite`
in this repository is one library among many.

## The file

- SQLite 3, rollback journal (`journal_mode` DELETE, never WAL).
- `PRAGMA application_id = 1196447556` ('GPWD'). The app refuses any other file.
- `PRAGMA user_version` is the format version, now 7. The app opens only the version it was
  built for; `go run ./cmd/library migrate <file>` brings an older file up to date.
- The tables are exactly those in `db/schema.sql`, which documents every column. Make new
  files with `go run ./cmd/library create <file>`, not by hand.
- Any file name and folder work. When the file sits inside a git work tree, the app pulls
  before opening it and commits and pushes only that file. Elsewhere, changes stay on the Mac.

## Content

A producer fills the lesson tables and leaves the learner's tables empty.

- **Syllabus**:
  - `course` (kind 'Course' or 'Guided Project'), then `chapter`, then `lesson`.
  - Each list is ordered by `position`, counted from 0, and unique within its parent.
  - The sidebar shows this order exactly.
- **Lessons**: every lesson has exactly one row in the table for its type.

  | `lesson.type` | Table | What the app does |
  |---|---|---|
  | `type_code` | `code_lesson` + `starter_file` | Builds and runs the program; it passes when stdout equals `expected_output` |
  | `type_code_tests` | `code_lesson` + `starter_file` | Runs `go test`; it passes when every test passes and the output reports no failed case |
  | `type_choice` | `quiz_lesson`, `quiz_question`, `quiz_answer` | Grades each question against its one right answer |
  | `type_cli` | `cli_lesson`, `cli_step` and its parts | Runs the steps in order: commands under `/bin/zsh -c` in the course's folder, HTTP requests to the learner's server, each checked by its tests |
  | `type_github_checks` | `github_lesson`, `github_step` and texts | Runs each check against the learner's repository on GitHub, the course's `project.github_repo` |
  | `type_interview_chat` | `interview_lesson` | Shows the prompt and criteria; the learner marks the lesson done |

- **Code**: `prog_lang` is `go`, since the app runs code with the learner's Go toolchain. A
  lesson in another language still opens, and the app says it can't run it.
  Starter files with `is_hidden` are added at build time and never shown; `is_readonly`
  files are shown but can't be edited. `solution_file` holds the reference solution of each
  file the learner edits (neither hidden nor read-only); the app never shows or runs it.
  `go run ./cmd/library verify <file>` runs every code lesson with the Go toolchain: it must
  pass with its solution and fail with its starter, every run within 10 s.
- **Command-line steps**:
  - `${name}` in commands, URLs, headers and bodies is replaced with values captured by
    earlier steps. `${baseURL}` is the learner's server, resolved as described in
    `db/schema.sql` (`base_url_default`, `asks_for_base_url`, `server_address`,
    `project`).
  - jq programs follow jq 1.8.
  - HTTP behaves like Go's `net/http` client.
- **Readmes** are Markdown (CommonMark with GitHub tables, task lists and strikethrough),
  plus these extensions:
  - Callouts: `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`.
    `[!INFO]` shows as a note and `[!DANGER]` as a caution. Any other word shows as a note
    titled with that word.
  - Headings tagged for one system: `## [!windows] …`.
  - Superscript in prose, never in code: `m^e^`.

  Images, videos and HTML embeds are not shown, so leave them out. Other inline HTML shows
  as literal text.

## What the app checks on open

A file that fails any of these is refused with a message that names the problem:

1. The `application_id` and `user_version` above.
2. `PRAGMA quick_check` is `ok`, and `PRAGMA foreign_key_check` finds nothing.
3. Every lesson has exactly one row in its type's table, of the matching type.
4. Every quiz question has exactly one right answer.
5. Every `cli_step` has its command or request row, matching its kind.
6. Every `solution_file` solves an editable starter file of its lesson: one neither hidden
   nor read-only.

`go run ./cmd/library check <file>` (or `make check` for this repository's library) runs the
same checks, written once in the `db` package, and prints the same messages the app shows.
`create` makes a new empty library and `migrate` brings an older one up to date.

## Format 7 and migrating

Format 7 adds `project.github_repo`: the learner's repository on GitHub for a course, which
the course's GitHub lessons check. It holds `owner/name`, such as
`ismatsamadov/learn-cicd-starter` for `https://github.com/ismatsamadov/learn-cicd-starter`,
and a CHECK holds it to GitHub's names:

- the owner: letters, digits and single hyphens, neither first nor last, at most 39
  characters;
- the name: letters, digits, `.`, `_` and `-`, at most 100 characters, and not `.` or `..`.

A project row may now hold only a repository, without a folder or a server address.

`go run ./cmd/library migrate <file>` brings a library of format 3 or later up to date in
place, then runs `check` on it:

- It takes one version at a time, each in one transaction: a step either finishes or leaves
  the file as it was.
- Every row is kept. From format 6, every project keeps its folder and address, and has no
  repository until the learner gives one.
- A file of a newer format, or one that is not a library, is refused and left as it is.

Quit the app before migrating the library it has open, and open the migrated library with an
app built for format 7.

## Authoring

`go run ./cmd/author` writes original content into any library: `course` and `chapter` add
or update one by slug, `lesson` imports a lesson package (a folder with the lesson's readme,
starter and solution files, or its quiz), and `export` writes lessons back out as packages,
byte for byte, to edit and import again. `go run ./cmd/author help` describes the package
layout.
