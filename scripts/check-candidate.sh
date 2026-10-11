#!/bin/zsh
set -eu
setopt pipefail
cd "${0:A:h}/.."
source_checkout="${PARAKEET_CORE_PATH:-$PWD/../parakeet-ane-server}"
source_ref="${PARAKEET_CORE_REF:-$(python3 -c 'import json; pins=json.load(open("Package.resolved"))["pins"]; print(next(pin["state"]["revision"] for pin in pins if pin["identity"] == "parakeet-ane-server"))')}"
pin_snapshot=$(mktemp)
cp Package.resolved "$pin_snapshot"
trap 'cp "$pin_snapshot" Package.resolved; /bin/rm -f "$pin_snapshot"' EXIT
revision=$(git -C "$source_checkout" rev-parse "$source_ref^{commit}")
candidate="$PWD/.build/candidates/$revision/parakeet-ane-server"
mkdir -p "$candidate"
git -C "$source_checkout" archive "$revision" | tar -x -C "$candidate"
print "Testing committed batch candidate $revision (cached models only)"
export PARAKEET_CORE_PATH="$candidate"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --disable-sandbox --disable-keychain --manifest-cache none --cache-path .build/package-cache --scratch-path .build/candidate
.build/candidate/arm64-apple-macosx/release/whispr-bench --candidate-check
