# Gopherwood

A quiet, native macOS app for learning Go offline: boot.dev's Go courses on the left, the
lesson in the middle, your own Go toolchain checking your code. No browser, no local web
server, no pictures or videos.

It is a personal tool, never published or sold, and nothing here goes to an app store. The
lessons are a personal copy of boot.dev's Go courses for offline study.

## All data is one SQL database

Lessons, progress, every Run and Submit, notes and your code live in one SQLite database,
`~/Library/Application Support/Gopherwood/gopherwood.sqlite`. Nothing is kept as JSON or loose
files. In git the database travels as SQL text, so a commit stores only the rows that changed:

| File | Repository | Holds | Written by |
|---|---|---|---|
| `db/lessons.sql` | jobloom/gopherwood (private) | courses, chapters, lessons | `sync/` |
| `study.sql` | jobloom/gopherwood-study (private) | your progress, attempts, notes, settings and code | the app, as you study |

To build and run your code the app writes a lesson's files to a scratch folder and reads them
back from there; the database is where they live.

## A new laptop

1. `gh repo clone jobloom/gopherwood`, then build and install the app. It loads
   `db/lessons.sql` into a fresh database.
2. `gh repo clone jobloom/gopherwood-study ~/Documents/Gopherwood`. The app loads `study.sql`
   and from then on commits and pushes it as you study.

## Parts

| Path | What it is |
|---|---|
| `db/schema.sql` | The database's tables |
| `db/lessons.sql` | The lessons as SQL, images and videos removed |
| `sync/` | Go tool: fetches new or changed lessons from boot.dev into the database and `db/lessons.sql` |
| `app/` | The SwiftUI app |

## Requirements

- macOS 14 or later, Xcode Command Line Tools (`xcode-select --install`)
- Go, for the lessons and for `sync/`
