.PHONY: build run run-rel test clean web web-serve web-run fly-stage fly-deploy

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

# --- Web/WASM targets ---
# Requires the speech engine built for wasm in DrSbaitsoLib first: `make native-lib-emscripten` there.

PORT ?= 8000

# Builds the browser version -> zig-out/web/ (index.html + DrSbaitsoUI.js/.wasm).
web:
	zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall

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

# Builds for the web and stages only what the page needs into fly/site/
# (no source maps or emscripten's default shell page).
fly-stage: web
	@test -f fly/fly.toml || (echo "fly/ is missing (it's local only, not in git)" && exit 1)
	rm -rf $(FLY_SITE)
	mkdir -p $(FLY_SITE)
	cp zig-out/web/index.html zig-out/web/DrSbaitsoUI.js zig-out/web/DrSbaitsoUI.wasm $(FLY_SITE)/

# Stages a fresh build, then deploys it to fly.io as a single machine.
fly-deploy: fly-stage
	cd fly && flyctl deploy --ha=false
