.PHONY: build run run-rel test clean release macos-app windows-app web web-serve web-run fly-stage fly-deploy

# Native debug build.
build:
	zig build

run:
	zig build run

run-rel:
	zig build run -Doptimize=ReleaseSafe

# Runs all unit tests (src/main.zig and everything it imports), printing
# each test as it runs via the custom runner wired up in build.zig
# (test_runner.zig) -- Zig's default runner stays silent on passing tests
# when attached to a real terminal.
test:
	zig build test

clean:
	rm -rf .zig-cache zig-out

# --- Release packages ---
# All release artifacts -> zig-out/dist/: macOS .app bundles for Apple Silicon
# and Intel, plus a Windows x64 build, each zipped for a GitHub release. All are
# cross-compiled by Zig (ReleaseSafe). The speech engine is built per target
# inside DrSbaitsoLib (never copied here). Override APP_VERSION, MACOS_MIN or
# SBAITSO_LIB, e.g. `make release APP_VERSION=1.2.0`.
release: macos-app windows-app

macos-app:
	APP_VERSION=$(APP_VERSION) MACOS_MIN=$(MACOS_MIN) SBAITSO_LIB=$(SBAITSO_LIB) ./tools/package-macos.sh

windows-app:
	APP_VERSION=$(APP_VERSION) SBAITSO_LIB=$(SBAITSO_LIB) ./tools/package-windows.sh

APP_VERSION ?= 1.0.0
MACOS_MIN ?= 11.0
SBAITSO_LIB ?= ../DrSbaitsoLib

# --- Web/WASM targets ---
# Requires the speech engine built for wasm in DrSbaitsoLib first: `make native-lib-emscripten` there.

PORT ?= 8000

# Builds the browser version -> zig-out/web/ (index.html + DrSbaitsoUI.js/.wasm).
# The page's download links name the zips by version, so __APP_VERSION__ is
# filled in here. Already-packaged zips (zig-out/dist/) are copied into
# downloads/ when present so the links also work under `make web-serve`;
# `make fly-stage` always packages fresh ones first.
web:
	zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
	perl -pi -e 's/__APP_VERSION__/$(APP_VERSION)/g' zig-out/web/index.html
	rm -rf zig-out/web/downloads
	@if ls zig-out/dist/DrSbaitsoReborn-$(APP_VERSION)-*.zip >/dev/null 2>&1; then \
		mkdir -p zig-out/web/downloads && \
		cp zig-out/dist/DrSbaitsoReborn-$(APP_VERSION)-*.zip zig-out/web/downloads/; \
	else \
		echo "note: no v$(APP_VERSION) desktop zips in zig-out/dist/ (run 'make release'); download links will 404 locally"; \
	fi

# Serves the web build locally on http://localhost:$(PORT)/
web-serve:
	@test -f zig-out/web/index.html || (echo "run 'make web' first" && exit 1)
	@echo "Open http://localhost:$(PORT)/"
	python3 -m http.server $(PORT) --bind 127.0.0.1 -d zig-out/web

# Builds for the web, then serves it.
web-run: web web-serve

# --- Fly.io targets ---
# The fly/ folder (Dockerfile, nginx.conf, fly.toml) is local only and gitignored.

FLY_SITE := fly/site

# Packages fresh desktop builds, builds for the web, and stages only what the
# page needs into fly/site/ (no source maps or emscripten's default shell
# page), with the desktop zips under downloads/.
fly-stage:
	@test -f fly/fly.toml || (echo "fly/ is missing (it's local only, not in git)" && exit 1)
	$(MAKE) release
	$(MAKE) web
	rm -rf $(FLY_SITE)
	mkdir -p $(FLY_SITE)/downloads
	cp zig-out/web/index.html zig-out/web/DrSbaitsoUI.js zig-out/web/DrSbaitsoUI.wasm $(FLY_SITE)/
	cp zig-out/dist/DrSbaitsoReborn-$(APP_VERSION)-*.zip $(FLY_SITE)/downloads/

# Stages a fresh build, then deploys it to fly.io as a single machine.
fly-deploy: fly-stage
	cd fly && flyctl deploy --ha=false
