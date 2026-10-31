# Gopherwood

A quiet, native macOS app for learning Go offline: boot.dev's Go courses on the left, the
lesson in the middle, your own Go toolchain checking your code. No browser, no local web
server, no pictures or videos.

It is a personal tool, never published or sold, and nothing here goes to an app store. The
lessons are a personal copy of boot.dev's Go courses for offline study.

## All data is one SQLite database, in git

Lessons, your progress, every Run and Submit, notes and your code live in one database file,
`data/gopherwood.sqlite`, committed to this repository as it is. Nothing is kept as JSON or
loose files. The app reads and writes it here and commits and pushes only that file as you
study; `sync/` adds new or changed lessons to it.

To build and run your code the app writes a lesson's files to a scratch folder and reads them
back; the database is where they live.

## A new laptop

`gh repo clone jobloom/gopherwood`, build and install the app, open it. The database comes
with the clone.

## Parts

| Path | What it is |
|---|---|
| `data/gopherwood.sqlite` | The database: lessons, your progress, attempts, notes and code |
| `db/schema.sql` | Its tables |
| `sync/` | Go tool: fetches new or changed lessons from boot.dev into the database |
| `app/` | The SwiftUI app |

## Requirements

- macOS 14 or later, Xcode Command Line Tools (`xcode-select --install`)
- Go, for the lessons and for `sync/`
