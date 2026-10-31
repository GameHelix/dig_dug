# Gopherwood

A quiet, native macOS app for learning Go offline: boot.dev's Go courses on the left, the
lesson in the middle, your own Go toolchain checking your code. No browser, no local web
server, no pictures or videos.

It is a personal tool, never published or sold, and nothing here goes to an app store. The
lessons are a personal copy of boot.dev's Go courses for offline study, kept in this private
repository as text so that a new laptop needs nothing but a clone.

## A new laptop

1. `gh repo clone jobloom/gopherwood` and build and install the app.
2. `gh repo clone jobloom/gopherwood-study ~/Documents/Gopherwood`: your code, progress,
   attempts and notes. The app commits and pushes them there as you study.

The local SQLite database is rebuilt from `lessons/` and your study repository; it is never
committed.

## Parts

| Path | What it is |
|---|---|
| `lessons/` | The lessons as text, one JSON file per lesson with images and videos removed |
| `db/schema.sql` | The local database: lessons (loaded from `lessons/` by `sync/`) and your study data (kept by the app) |
| `sync/` | Go tool that fills the database: imports lessons already saved as JSON, fetches new or changed ones from boot.dev, strips images and videos |
| `app/` | The SwiftUI app |

## Where things are

- Database: `~/Library/Application Support/Gopherwood/gopherwood.sqlite`
- Your code: `~/Documents/Gopherwood/<course>/<chapter>/<lesson>/`, one small Go module per
  lesson, so `go build` and `go test` work on it in a terminal too.

## Requirements

- macOS 14 or later, Xcode Command Line Tools (`xcode-select --install`)
- Go, for the lessons and for `sync/`
