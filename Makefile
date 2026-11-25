.PHONY: build test install uninstall status doctor check cleanup-helper cleanup-prepare cleanup-verify cleanup-install cleanup-uninstall
SWIFT_ENV = CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swift-cache
SWIFT_FLAGS = --disable-sandbox --cache-path .build/package-cache --manifest-cache none --disable-keychain
build:
	./scripts/build-app.sh
test:
	python3 -c 'import ast, pathlib; [ast.parse(path.read_text(), filename=str(path)) for path in pathlib.Path("scripts").glob("*.py")]'
	$(SWIFT_ENV) swift test $(SWIFT_FLAGS)
	python3 scripts/test-cli.py
	./scripts/test-media.py
	python3 scripts/test-release.py
	python3 scripts/test-latency.py
install: build
	./scripts/install-app.sh
uninstall:
	./scripts/install-app.sh --uninstall
status:
	./scripts/doctor.sh --status
doctor:
	./scripts/doctor.sh
check: test build doctor
	"dist/Whispr Lite.app/Contents/MacOS/WhisprLite" --smoke-test
cleanup-helper:
	$(SWIFT_ENV) swift build $(SWIFT_FLAGS) --product WhisprLiteCleanup
# MODEL=s1-mini prepares or installs another cleanup model from Resources/cleanup-stack.json.
CLEANUP_MODEL = $(if $(MODEL),--model $(MODEL))
cleanup-prepare: cleanup-helper
	.build/debug/WhisprLiteCleanup prepare --kit "$(CURDIR)" $(CLEANUP_MODEL)
cleanup-verify: cleanup-helper
	.build/debug/WhisprLiteCleanup verify --kit "$(CURDIR)" $(CLEANUP_MODEL)
cleanup-install: cleanup-helper
	.build/debug/WhisprLiteCleanup install --kit "$(CURDIR)" $(CLEANUP_MODEL)
cleanup-uninstall: cleanup-helper
	.build/debug/WhisprLiteCleanup uninstall --kit "$(CURDIR)"
