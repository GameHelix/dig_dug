# Gopherwood: build and install the app, run every test, sync the lessons.
.PHONY: app install test sync

APP := build/Gopherwood.app

app:
	swift build -c release --package-path app --product Gopherwood
	app/scripts/bundle.sh "$$(swift build -c release --package-path app --show-bin-path)/Gopherwood" $(APP)

install: app
	rm -rf ~/Applications/Gopherwood.app
	mkdir -p ~/Applications
	ditto $(APP) ~/Applications/Gopherwood.app

test:
	go test ./...
	swift test --package-path app

sync:
	go run ./cmd/sync
