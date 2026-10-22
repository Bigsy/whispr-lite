#!/bin/zsh
# Source from repository-rooted build scripts.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift_flags=(--disable-sandbox --cache-path .build/package-cache --manifest-cache none --disable-keychain)
