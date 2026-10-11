#!/bin/zsh
set -eu
cd "${0:A:h}/.."
framework="$PWD/.build/media-upstream/MediaRemoteAdapter.framework"
mkdir -p "$framework/Versions/A/Resources"
task_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
min_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
xcrun clang -isysroot "$task_sdk_path" -arch arm64 "-mmacosx-version-min=$min_macos" -dynamiclib -fobjc-arc -fvisibility=default \
  -I Vendor/mediaremote-adapter/include -I Vendor/mediaremote-adapter/src \
  Vendor/mediaremote-adapter/src/adapter/{env,get,globals,keys,now_playing,repeat,seek,send,shuffle,speed,stream}.m \
  Vendor/mediaremote-adapter/src/private/*.m \
  Vendor/mediaremote-adapter/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
  -o "$framework/Versions/A/MediaRemoteAdapter"
cp Resources/MediaFramework.plist "$framework/Versions/A/Resources/Info.plist"
ln -sfn A "$framework/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$framework/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$framework/Resources"
codesign --force --sign - "$framework"
