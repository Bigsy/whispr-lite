.PHONY: build test install uninstall status doctor bench-media check candidate-check cleanup-prepare cleanup-install cleanup-uninstall
SWIFT_ENV = CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swift-cache
SWIFT_FLAGS = --disable-sandbox --cache-path .build/package-cache --manifest-cache none --disable-keychain
build:
	./scripts/build-app.sh
test:
	python3 -c 'import ast, pathlib; [ast.parse(path.read_text(), filename=str(path)) for path in pathlib.Path("scripts").glob("*.py")]'
	$(SWIFT_ENV) swift test $(SWIFT_FLAGS)
	python3 scripts/test-app-cli.py
	python3 scripts/test-bench-cli.py
	./scripts/test-media.py
	python3 scripts/test-setup.py
	python3 scripts/test-release.py
install: build
	./scripts/install-app.sh
uninstall:
	./scripts/install-app.sh --uninstall
status:
	./scripts/doctor.sh --status
doctor:
	./scripts/doctor.sh
bench-media:
	./scripts/bench-media.py
check: test build doctor
	"dist/Whispr Lite.app/Contents/MacOS/WhisprLite" --smoke-test
candidate-check:
	./scripts/check-candidate.sh
cleanup-prepare:
	python3 scripts/cleanup-service.py prepare
cleanup-install:
	python3 scripts/cleanup-service.py install
cleanup-uninstall:
	python3 scripts/cleanup-service.py uninstall
