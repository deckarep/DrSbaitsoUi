.PHONY: clean web web-rel web-relsm run run-rel http zip

clean:
	rm -rf .zig-cache zig-out

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

run:
	zig build run

run-rel:
	zig build run -Doptimize=ReleaseSafe

http:
	python3 main.py
