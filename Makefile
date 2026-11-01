# Gopherwood: build and install the app, run every test, check the library.
.PHONY: app install test check

APP := build/Gopherwood.app
LIBRARY := $(CURDIR)/data/gopherwood.sqlite
BUNDLE_ID := io.github.jobloom.Gopherwood

app:
	swift build -c release --package-path app --product Gopherwood
	app/scripts/bundle.sh "$$(swift build -c release --package-path app --show-bin-path)/Gopherwood" $(APP)

# Checks this clone's library, installs the app and, the first time only, points it at the library.
install: app check
	rm -rf ~/Applications/Gopherwood.app
	mkdir -p ~/Applications
	ditto $(APP) ~/Applications/Gopherwood.app
	defaults read $(BUNDLE_ID) LibraryPath >/dev/null 2>&1 || defaults write $(BUNDLE_ID) LibraryPath "$(LIBRARY)"

test:
	go test ./...
	swift test --package-path app

check:
	go run ./cmd/library check "$(LIBRARY)"

