# Gopherwood

A quiet, native macOS app for learning Go offline: boot.dev's Go courses on the left, the
lesson in the middle, your own Go toolchain checking your code. No browser, no local web
server, no pictures or videos.

It is a personal tool for one Mac. The lessons are a personal copy of boot.dev's Go courses
for offline study: they live only in the local database and are never committed, published
or distributed. Nothing here goes to an app store.

## Parts

| Path | What it is |
|---|---|
| `db/schema.sql` | The database: lessons (refreshed by `sync/`) and your study data (kept by the app) |
| `sync/` | Go tool that fills the database: imports lessons already saved as JSON, fetches new or changed ones from boot.dev, strips images and videos |
| `app/` | The SwiftUI app |

## Where things are

- Database: `~/Library/Application Support/Gopherwood/gopherwood.sqlite`
- Your code: `~/Documents/Gopherwood/<course>/<chapter>/<lesson>/`, one small Go module per
  lesson, so `go build` and `go test` work on it in a terminal too.

## Requirements

- macOS 14 or later, Xcode Command Line Tools (`xcode-select --install`)
- Go, for the lessons and for `sync/`
