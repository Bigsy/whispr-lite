# Installing Whispr Lite

Requires Apple Silicon and macOS 14+. Download the `.dmg` from the GitHub release, open it
and drag **Whispr Lite** onto **Applications**. The app ZIP holds the same app for scripted
installs; the GitHub-generated source archives are for developers. Verify a download against
the release's SHA256SUMS file if needed.

Preview assets are not notarized. macOS blocks their first launch: open the app once, then
choose **Open Anyway** in System Settings > Privacy & Security, or run
`xattr -dr com.apple.quarantine "/Applications/Whispr Lite.app"`. Preview builds are also
ad-hoc signed, so updating can require granting permissions again. Developer ID-signed,
notarized releases avoid the first-launch workaround and normally preserve permissions
across updates. All builds still require the initial Microphone and Accessibility grants.

## Local cleanup service

Settings can install it: while setup is incomplete, the status box at the top lists
Permissions, Speech model and Cleanup, and the Cleanup row offers **Install…**. It
downloads about 2.7 GB with progress (Cancel keeps what has downloaded, and the next
install resumes it), then adds the "Whispr Lite Cleanup" login item. The app includes a
signed native helper; Python, Homebrew and Apple's developer tools are not required.

To set it up from Terminal instead, download and unzip the matching `Cleanup-Setup.zip`.
It includes the same native helper; no Python, Swift/Xcode build or Homebrew is needed.
Change into the extracted `WhisprLite-Cleanup-Setup` folder and run:

```sh
"./Whispr Lite Cleanup" prepare
"./Whispr Lite Cleanup" verify
"./Whispr Lite Cleanup" install
```

This explicitly downloads about 2.7 GB of checksum-verified Gemma/MTP weights and the
pinned standalone llama.cpp runtime, then installs an owned user LaunchAgent on port
11436. It preserves existing settings/models and refuses a conflicting service.
To remove that service while keeping models/settings:

```sh
"./Whispr Lite Cleanup" uninstall
```

## First launch

Open the app and its Settings. The status box lists what is left: use **Grant…** for each
missing permission, click **Download** for the speech model (about 600 MB for the default
Unified model) and **Install…** for cleanup. Both downloads show their progress and can
run at the same time. Record your hold shortcut in General, then focus a text field, hold
your shortcut and speak. Model downloads need internet access; dictation runs locally
afterwards.

The permission buttons request access so Whispr Lite appears in System Settings. Enable
its Accessibility switch there. A separate Input Monitoring grant is not required:
Accessibility also covers the keyboard shortcut. If macOS asks to quit and reopen the
app, do so, then choose **Check readiness**.

New installs have an empty dictionary and the general cleanup prompt. Private preferences,
prompts and dictionaries are not included in releases. For an exact recurring correction,
add `spoken phrase > Written phrase` on its own line in the Cleanup dictionary.

## Privacy

Audio is not saved by default. **Save recordings for debugging** in Advanced is optional
and keeps up to 500 MB of local WAV files. **Keep dictation history on this Mac** in Cleanup
is on by default and keeps up to 32 MB of original and cleaned text. Both can be deleted
in Settings, are excluded from Time Machine and are never uploaded.

Installing cleanup from Settings on a fresh Mac remains under validation. Preview releases
are for testing; microphone, destination-app and media-player compatibility checks remain
open.
