#!/bin/zsh
set -eu
cd "${0:A:h}/.."
print 'Toolchain:'
swift --version
print "macOS: $(sw_vers -productVersion); architecture: $(uname -m)"
[[ $(uname -m) == arm64 ]] || exit 1
print 'Service health (read-only; missing services do not invalidate a fake development build):'
for port in 11434 11435 11436; do
  if curl --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null; then
    print "127.0.0.1:$port healthy"
  else
    print "127.0.0.1:$port unavailable"
  fi
  lsof -n -iTCP:$port -sTCP:LISTEN || true
  if [[ "$port" == 11434 ]] && lsof -n -iTCP:11434 -sTCP:LISTEN -Fc 2>/dev/null | rg -q '^collama$'; then
    print 'Port 11434 is owned by Ollama; Whispr Lite cleanup defaults to separate port 11436.'
  fi
done
if [[ "${1:-}" != --status ]]; then
  plutil -lint Resources/Info.plist Resources/MediaFramework.plist
  if [[ -d 'dist/Whispr Lite.app' ]]; then codesign --verify --deep --strict 'dist/Whispr Lite.app'; fi
  print 'Manual permissions, hardware capture, focus/clipboard and player matrix remain required.'
fi
