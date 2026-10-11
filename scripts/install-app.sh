#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# Explicit install/uninstall only. Neither action touches model services, model files or settings.
destination="${APP_INSTALL_DIR:-$HOME/Applications}/Whispr Lite.app"
if [[ "${1:-}" == --uninstall ]]; then
  [[ "$destination" == */Whispr\ Lite.app ]] || { print -u2 "Refusing to remove unexpected path: $destination"; exit 1; }
  /bin/rm -rf "$destination"
else
  mkdir -p "${destination:h}"
  staged="$destination.new"
  /bin/rm -rf "$staged"
  ditto "dist/Whispr Lite.app" "$staged"
  if ! codesign --verify --deep --strict "$staged"; then
    /bin/rm -rf "$staged"
    print -u2 'Staged app failed signature verification'
    exit 1
  fi
  /bin/rm -rf "$destination"
  mv "$staged" "$destination"
fi
