# Installing Whispr Lite

Requires Apple Silicon and macOS 14+. Download the `.dmg` from the GitHub release, open it
and drag **Whispr Lite** onto **Applications**. The app ZIP holds the same app for scripted
installs; the GitHub-generated source archives are for developers. Verify a download against
the release's SHA256SUMS file if needed.

Preview assets are not notarized. macOS blocks their first launch: open the app once, then
choose **Open Anyway** in System Settings > Privacy & Security, or run
`xattr -dr com.apple.quarantine "/Applications/Whispr Lite.app"`. Preview builds are also
ad-hoc signed, so macOS asks again for Microphone, Accessibility and Input Monitoring after
each update. Notarized releases need neither step.

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
