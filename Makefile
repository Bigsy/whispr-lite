.PHONY: build test install uninstall status doctor bench bench-media check candidate-check cleanup-prepare cleanup-install cleanup-uninstall
build:
	./scripts/build-app.sh
test:
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swift-cache swift test --disable-sandbox --cache-path .build/package-cache --manifest-cache none --disable-keychain
	./scripts/test-media.py
	python3 scripts/test-setup.py
install: build
	./scripts/install-app.sh
uninstall:
	./scripts/install-app.sh --uninstall
status:
	./scripts/doctor.sh --status
doctor:
	./scripts/doctor.sh
bench:
	mkdir -p bench/results
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swift-cache swift run -c release --disable-sandbox --disable-keychain --manifest-cache none --cache-path .build/package-cache whispr-bench > bench/results/fake-orchestration.json
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
