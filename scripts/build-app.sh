#!/bin/zsh
set -eu
cd "${0:A:h}/.."
source scripts/swift-env.sh
task_scratch_path=.build
export SWIFT_EXEC="$PWD/scripts/swiftc-app.py"
export WHISPR_SWIFTC_PATH="$(xcrun --find swiftc)"
swift build --scratch-path "$task_scratch_path" -c release --arch arm64 "${swift_flags[@]}"
scripts/build-media.sh
# Follow SwiftPM's current output link; SDK/toolchain updates can change its layout.
# A hard-coded target triple can package an old executable left in the build cache.
binary_dir="$PWD/$task_scratch_path/release"
[[ -x "$binary_dir/WhisprLite" ]] || { print -u2 "Missing built app executable: $binary_dir/WhisprLite"; exit 1; }
app="$PWD/dist/Whispr Lite.app"
/bin/rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$app/Contents/Helpers"
cp "$binary_dir/WhisprLite" "$app/Contents/MacOS/WhisprLite"
cp "$binary_dir/WhisprLiteCleanup" "$app/Contents/Helpers/Whispr Lite Cleanup"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
if [[ -n "${APP_VERSION:-}" ]]; then
  [[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid APP_VERSION'; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${APP_BUILD_NUMBER:-}" ]]; then
  [[ "$APP_BUILD_NUMBER" =~ '^[0-9]+$' ]] || { print -u2 'Invalid APP_BUILD_NUMBER'; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp Vendor/mediaremote-adapter/patches/broker.pl "$app/Contents/Resources/"
cp Vendor/mediaremote-adapter/LICENSE "$app/Contents/Resources/MediaRemoteAdapter-LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
# Native cleanup setup resources. No Python scripts or interpreter ship in the app.
setup_kit="$app/Contents/Resources/CleanupSetup"
for file in Resources/cleanup-stack.json Resources/cleanup-prompt.txt Resources/cleanup-fixtures.json LICENSE THIRD_PARTY_NOTICES.md; do
  mkdir -p "$setup_kit/${file:h}"
  cp "$file" "$setup_kit/$file"
done
parakeet_source="$PWD/$task_scratch_path/checkouts/parakeet-ane-server"
fluid_source="$PWD/$task_scratch_path/checkouts/FluidAudio"
for required in "$parakeet_source/LICENSE" "$parakeet_source/THIRD_PARTY_NOTICES.md" \
  "$fluid_source/LICENSE" "$fluid_source/ThirdPartyLicenses"; do
  [[ -e "$required" ]] || { print -u2 "Missing required third-party licence: $required"; exit 1; }
done
mkdir -p "$app/Contents/Resources/Licenses/FluidAudio"
cp "$parakeet_source/LICENSE" "$app/Contents/Resources/Licenses/ParakeetCore-MIT.txt"
cp "$parakeet_source/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/Licenses/ParakeetCore-NOTICES.md"
cp "$fluid_source/LICENSE" "$app/Contents/Resources/Licenses/FluidAudio/Apache-2.0.txt"
cp -R "$fluid_source/ThirdPartyLicenses" "$app/Contents/Resources/Licenses/FluidAudio/"
cp LICENSE "$app/Contents/Resources/Licenses/WhisprLite-MIT.txt"
cp -R "$app/Contents/Resources/Licenses" "$setup_kit/"
cp -R .build/media/MediaRemoteAdapter.framework "$app/Contents/Frameworks/"
# SwiftPM resources must accompany a candidate that packages CoreML/resource bundles.
for resource in "$binary_dir"/*.bundle(N); do cp -R "$resource" "$app/Contents/Resources/"; done
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)".*/\1/p' | head -1)
fi
[[ -n "$identity" ]] || identity=-
sign_options=()
if [[ "${DISTRIBUTION_SIGNING:-0}" == 1 ]]; then
  [[ "$identity" != - ]] || { print -u2 'Distribution requires a Developer ID identity'; exit 1; }
  sign_options+=(--options runtime --timestamp)
fi
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then sign_options+=(--keychain "$SIGN_KEYCHAIN"); fi
codesign --force --sign "$identity" "${sign_options[@]}" "$app/Contents/Helpers/Whispr Lite Cleanup"
codesign --force --sign "$identity" "${sign_options[@]}" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$identity" "${sign_options[@]}" --entitlements Resources/App.entitlements "$app"
codesign --verify --deep --strict "$app"
print "Built $app (signature: $identity)"
