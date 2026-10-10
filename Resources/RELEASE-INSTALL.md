# Installing Whispr Lite

Requires Apple Silicon and macOS 14+. Download the app ZIP asset from the GitHub release,
unzip it and move `Whispr Lite.app` into Applications. The GitHub-generated source archives
are for developers. Preview assets are not notarized; use a notarized release for normal
installation. Verify the download against the release's SHA256SUMS file if needed.

## Local cleanup service

Cleanup setup is currently separate from the app. Download and unzip the matching
`Cleanup-Setup.zip`. It requires Python 3.9+ already installed; no Swift/Xcode build or
Homebrew is needed. In Terminal, change into the extracted `WhisprLite-Cleanup-Setup`
folder and run:

```sh
python3 scripts/cleanup-service.py prepare
python3 scripts/cleanup-service.py verify
python3 scripts/cleanup-service.py install
```

This explicitly downloads about 2.7 GB of checksum-verified Gemma/MTP weights and the
pinned standalone llama.cpp runtime, then installs an owned user LaunchAgent on port
11436. It preserves existing settings/models and refuses a conflicting service.
To remove that service while keeping models/settings:

```sh
python3 scripts/cleanup-service.py uninstall
```

## First launch

Open the app. In General, grant Microphone, Accessibility and Input Monitoring access
and record your hold shortcut. In Advanced, enable downloads of missing ASR models.
Save and check readiness, then focus a text field, hold your shortcut and speak.
Model downloads need internet access; dictation runs locally afterwards.

New installs have an empty dictionary and the general cleanup prompt. Private preferences,
prompts and dictionaries are not included in releases. For an exact recurring correction,
add `spoken phrase > Written phrase` on its own line in the Cleanup dictionary.

Fully integrated first-run cleanup provisioning and installation on another Mac remain
under validation. Preview releases are for testing; the hardware/player acceptance matrix
is still open.
