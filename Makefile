.PHONY: build run run-rel test clean web web-rel web-relsm zip http

# Native debug build.
build:
	zig build

run:
	zig build run

run-rel:
	zig build run -Doptimize=ReleaseSafe

# Runs all unit tests (src/main.zig and everything it imports).
test:
	zig build test

clean:
	rm -rf .zig-cache zig-out

# --- Web/WASM targets (not yet revisited for Zig 0.16, kept for later) ---

web:
	zig build -Dtarget=wasm32-emscripten
	$(MAKE) zip

web-rel:
	zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSafe
	$(MAKE) zip

web-relsm:
	zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall
	cp index.html zig-out/web/
	rm zig-out/web/yourname.html
	$(MAKE) zip
	open zig-out/web/

zip:
	rm -f zig-out/web/Archive.zip
	cd zig-out/web && zip -9 Archive.zip index.html yourname.js yourname.wasm

# Serves the wasm build locally.
http:
	python3 -m http.server -d zig-out/web
