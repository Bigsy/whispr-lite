#!/bin/zsh
set -eu
cd "${0:A:h}/.."
print 'Toolchain:'
swift --version
print "macOS: $(sw_vers -productVersion); architecture: $(uname -m)"
[[ $(uname -m) == arm64 ]] || exit 1
print 'Service health (read-only; missing services do not invalidate a fake development build):'
asr_port=$(python3 -c 'import json, urllib.parse; print(urllib.parse.urlparse(json.load(open("Resources/config.example.json"))["asrEndpoint"]).port)')
cleanup_port=$(python3 -c 'import json; print(json.load(open("Resources/cleanup-stack.json"))["port"])')
for port in 11434 "$asr_port" "$cleanup_port"; do
  if curl --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null; then
    print "127.0.0.1:$port healthy"
  else
    print "127.0.0.1:$port unavailable"
  fi
  listener=$(lsof -n -iTCP:$port -sTCP:LISTEN 2>/dev/null || true)
  [[ -z "$listener" ]] || print -r -- "$listener"
  if [[ "$port" == 11434 ]] && print -r -- "$listener" | grep -Eq '^ollama[[:space:]]'; then
    print "Port 11434 is owned by Ollama; Whispr Lite cleanup defaults to separate port $cleanup_port."
  fi
done
if [[ "${1:-}" != --status ]]; then
  plutil -lint Resources/Info.plist Resources/MediaFramework.plist
  if [[ -d 'dist/Whispr Lite.app' ]]; then codesign --verify --deep --strict 'dist/Whispr Lite.app'; fi
  print 'Manual permissions, hardware capture, focus/clipboard and player matrix remain required.'
fi
