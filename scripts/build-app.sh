#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
task_scratch_path=.build
export SWIFT_EXEC="$PWD/scripts/swiftc-app.py"
if [[ -n "${PARAKEET_CORE_PATH:-}" ]]; then
  task_scratch_path=.build/candidate
fi
swift build --scratch-path "$task_scratch_path" -c release --arch arm64 --disable-sandbox --cache-path .build/package-cache --manifest-cache none --disable-keychain
scripts/build-media.sh
binary_dir=$(swift build --scratch-path "$task_scratch_path" -c release --arch arm64 --disable-sandbox --cache-path .build/package-cache --manifest-cache none --disable-keychain --show-bin-path)
app="$PWD/dist/Whispr Lite.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary_dir/WhisprLite" "$app/Contents/MacOS/WhisprLite"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/*.txt "$app/Contents/Resources/"
cp Vendor/mediaremote-adapter/patches/broker.pl "$app/Contents/Resources/"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$app/Contents/Resources/"
cp Vendor/mediaremote-adapter/LICENSE "$app/Contents/Resources/MediaRemoteAdapter-LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
parakeet_source="${PARAKEET_CORE_PATH:-$PWD/$task_scratch_path/checkouts/parakeet-ane-server}"
if [[ -d "$parakeet_source" ]]; then
  mkdir -p "$app/Contents/Resources/Licenses/FluidAudio"
  cp "$parakeet_source/LICENSE" "$app/Contents/Resources/Licenses/ParakeetCore-MIT.txt"
  cp "$parakeet_source/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/Licenses/ParakeetCore-NOTICES.md"
  cp "$task_scratch_path/checkouts/FluidAudio/LICENSE" "$app/Contents/Resources/Licenses/FluidAudio/Apache-2.0.txt"
  cp -R "$task_scratch_path/checkouts/FluidAudio/ThirdPartyLicenses" "$app/Contents/Resources/Licenses/FluidAudio/"
fi
cp -R .build/media/MediaRemoteAdapter.framework "$app/Contents/Frameworks/"
# SwiftPM resources must accompany a candidate that packages CoreML/resource bundles.
for resource in "$binary_dir"/*.bundle(N); do cp -R "$resource" "$app/Contents/Resources/"; done
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | head -1)
fi
[[ -n "$identity" ]] || identity=-
codesign --force --sign "$identity" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
print "Built $app (signature: $identity)"
