#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# Explicit install/uninstall only. Neither action touches model services, model files or settings.
destination="${APP_INSTALL_DIR:-$HOME/Applications}/Whispr Lite.app"
if [[ "${1:-}" == --uninstall ]]; then
  [[ "$destination" == */Whispr\ Lite.app ]] || exit 1
  rm -rf "$destination"
else
  mkdir -p "${destination:h}"
  ditto "dist/Whispr Lite.app" "$destination"
fi
