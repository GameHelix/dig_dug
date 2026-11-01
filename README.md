# Gopherwood

A quiet, native macOS app for learning Go offline: Go courses on the left, the
lesson in the middle, your own Go toolchain checking your code. No browser, no local web
server, no pictures or videos.

The app is not tied to any course. It opens a **library**: one SQLite file holding a
syllabus and your study data, in the format described in `docs/library-format.md`. Any file
in that format plugs in and works the same way.

This repository's library, `data/gopherwood.sqlite`, is a personal copy of boot.dev's Go
courses for offline study. It is data, not part of the app, and it never ships with it.

## A library is one SQLite database

Lessons, your progress, every Run and Submit, notes and your code live in one database file.
Nothing is kept as JSON or loose files. When the library sits in a git repository, as this
one does, File › Commit and Push Now commits and pushes only that file, and File › Pull
brings in changes. The app never runs git on its own.

To build and run your code the app writes a lesson's files to a scratch folder and reads them
back; the database is where they live.

Every part of a lesson has its own table: quiz questions and their answers, starter files,
each command-line step with its command or HTTP request, headers, form fields, captured values
and tests, and each GitHub check. Keys, foreign keys and checks keep bad data out: a quiz
question has one right answer, a test sets only its own kind's fields, a timestamp is UTC.
The one piece of JSON left is the body of an HTTP request a lesson sends to your server, kept
whole like a code file. `db/schema.sql` explains each table.

## A new laptop

`gh repo clone jobloom/gopherwood`, then `make install` in it, and open Gopherwood. The
first install points the app at this clone's library; File › Open Library… opens any other.

## Parts

| Path | What it is |
|---|---|
| `data/gopherwood.sqlite` | The database: lessons, your progress, attempts, notes and code |
| `db/schema.sql` | Its tables, constraints and conventions (schema version 6) |
| `db/` | The Go package that creates, opens, checks and migrates libraries |
| `cmd/library/` | Go tool for any library: `create`, `check`, `migrate` |
| `cmd/author/`, `internal/` | Go tool: writes lessons into a library from lesson packages, and exports them back |
| `app/` | The app: a Swift package with GopherwoodKit and the SwiftUI app |
| `docs/library-format.md` | The library format: what any library must hold, and what the app checks |
| `docs/architecture.md` | How the pieces fit together, and why |
| `docs/design.md` | How the app looks and behaves |
| `Makefile` | `make install` builds and installs the app; `make test`, `make check` |

## Requirements

- macOS 27 or later, Xcode Command Line Tools (`xcode-select --install`)
- Go 1.27 or later, for the lessons and the library tools
