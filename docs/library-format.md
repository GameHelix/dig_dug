# Library format

Gopherwood is not tied to any particular course. It opens a **library**: one SQLite file
that holds a syllabus (courses, chapters, lessons) and the learner's own data for it. Any
file in this format plugs in, and the app behaves the same with it. `data/gopherwood.sqlite`
in this repository is one library among many.

## The file

- SQLite 3, rollback journal (`journal_mode` DELETE, never WAL).
- `PRAGMA application_id = 1196447556` ('GPWD'). The app refuses any other file.
- `PRAGMA user_version` is the format version, now 5. The app opens only the version it was
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
  | `type_github_checks` | `github_lesson`, `github_step` and texts | Shows the checks as a list; the learner marks the lesson done |
  | `type_interview_chat` | `interview_lesson` | Shows the prompt and criteria; the learner marks the lesson done |

- **Code**: `prog_lang` is `go`, since the app runs code with the learner's Go toolchain. A
  lesson in another language still opens, and the app says it can't run it.
  Starter files with `is_hidden` are added at build time and never shown; `is_readonly`
  files are shown but can't be edited.
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

`go run ./cmd/library check <file>` (or `make check` for this repository's library) runs the
same checks, written once in the `db` package, and prints the same messages the app shows.
`create` makes a new empty library and `migrate` brings an older one up to date.
