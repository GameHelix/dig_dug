# Gopherwood

A quiet, native macOS app for learning Go offline: Go courses on the left, the
lesson in the middle, your own Go toolchain checking your code. No browser, no local web
server, no pictures or videos.

It is a personal tool, never published or sold, and nothing here goes to an app store. The
lessons are a personal copy of boot.dev's Go courses for offline study.

## All data is one SQLite database, in git

Lessons, your progress, every Run and Submit, notes and your code live in one database file,
`data/gopherwood.sqlite`, committed to this repository as it is. Nothing is kept as JSON or
loose files. The app reads and writes it here and commits and pushes only that file as you
study; the sync tool (`make sync`) adds new or changed lessons to it.

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
database comes with the clone.

## Parts

| Path | What it is |
|---|---|
| `data/gopherwood.sqlite` | The database: lessons, your progress, attempts, notes and code |
| `db/schema.sql` | Its tables, constraints and conventions (schema version 4) |
| `db/` | The Go package that creates, opens and checks the database |
| `cmd/sync/`, `internal/` | Go tool: fetches new or changed lessons from boot.dev into the database |
| `app/` | The app: a Swift package with GopherwoodKit and the SwiftUI app |
| `docs/architecture.md` | How the pieces fit together, and why |
| `docs/design.md` | How the app looks and behaves |
| `Makefile` | `make install` builds and installs the app; `make test`, `make sync` |

## Requirements

- macOS 27 or later, Xcode Command Line Tools (`xcode-select --install`)
- Go 1.27 or later, for the lessons and for the sync tool
