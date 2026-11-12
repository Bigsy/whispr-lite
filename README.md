# Whispr Lite

Local push-to-talk dictation for macOS. Hold a shortcut, speak, and release to paste
cleaned-up text into the app you're using.

**Your voice and dictation stay on your Mac.** Whispr Lite processes audio and text
locally, without sending them to cloud services.

Parakeet speech recognition uses Apple's Neural Engine (NPU) through Core ML. A local
Gemma model handles punctuation, self-corrections and cleanup on the GPU. Once the models
are downloaded, dictation works offline.

**Apple Silicon · macOS 14+ · Native Swift app**

Beta releases are available. Compatibility across microphones and apps is still being tested.

## Screenshots

Click any screenshot to view it at full size.

| General | Cleanup | Advanced |
| :---: | :---: | :---: |
| [<img src="images/img.png" alt="General settings: recording, shortcuts and permissions" width="240">](images/img.png) | [<img src="images/img_1.png" alt="Cleanup settings: prompt, dictionary and dictation history" width="240">](images/img_1.png) | [<img src="images/img_2.png" alt="Advanced settings: speech models, local services and diagnostics" width="240">](images/img_2.png) |

## Features

- **Tuned for Apple Silicon.** Speech recognition runs in the app, with the engine kept
  warm while you speak to reduce the wait after releasing the shortcut.
- **Fast local cleanup.** Quantised Gemma runs through Metal with multi-token prediction
  (MTP), cached prompts and benchmark-tuned inference settings.
- **Less work after release.** Low-latency audio capture and early cleanup of completed
  sentences in longer recordings feed directly into native text insertion.
- Choose your hold shortcut, including Globe/Fn or Left/Right Control.
- Choose an English or multilingual speech model.
- Add names, technical terms and exact phrase corrections to a private dictionary.
- Add your own context to the cleanup prompt, such as your work or terminology.
- Optionally pause media while recording and resume it afterwards.
- Press Escape to cancel, or use **Copy last result** to recover text.
- Turn off **Clean up dictation** for raw transcription, or opt into raw transcription
  during cleanup outages. Cleanup resumes on the next successful dictation.
- Possible missing audio is flagged separately from the dictated text; the captured
  result remains available to copy.

## Install

1. Download the app's `.dmg` from [Releases](https://github.com/Bigsy/whispr-lite/releases),
   and drag **Whispr Lite** into **Applications**.
2. Open the app and choose **Settings** from its menu bar icon.
3. Use **Grant…** to allow **Microphone** and **Accessibility**.
4. Use **Download** for the speech model and **Install…** for cleanup. Initial downloads
   total about **3.3 GB** with the default models.
5. Choose your hold shortcut in **General**, save your settings, and start dictating.

The cleanup service runs in the background and starts at login. Installing the app needs
no Python, Homebrew or developer tools.
See the [installation guide](Resources/RELEASE-INSTALL.md) for manual setup, service
removal and the first-launch steps for preview builds.

## Privacy

**Whispr Lite does not upload your recordings, transcripts, cleanup prompts or
dictionary.** Speech recognition and text cleanup run entirely on your Mac, and
dictation works offline once the models are installed.

Internet access is used to download models and runtime files, and to check for runtime
and app updates. Automatic app checks are opt-in in **Settings → General → App updates**;
manual checks are also available from the menu bar. These requests do not include your dictation. Text you paste into another app
is then subject to that app's own privacy and sync settings.

Settings, prompts and dictionaries stay under `~/Library/Application Support/WhisprLite/`.

- **Audio is not saved by default.** The optional **Save recordings for debugging** setting
  saves local WAV files, capped at 500 MB. It is off by default.
- **Dictation history is on by default.** It saves the original and cleaned text locally,
  capped at 32 MB. Turn it off or delete it in **Settings → Cleanup**.
- History and debug recordings are excluded from Time Machine and are never uploaded.
  Debug logging is also off by default and excludes dictated text.

The microphone starts when you press the shortcut. **Keep the microphone ready** optionally
keeps it running between dictations, with a short buffer in memory. This keeps the macOS
microphone indicator on, uses more power and prevents automatic idle sleep.

## Build from source

Requires Xcode with Swift 6.2+ and Python 3.9+ for development tooling.

```sh
make build
open 'dist/Whispr Lite.app'
```

Use the same Settings steps to download models and set up cleanup.

```sh
make test    # Automated tests
make check   # Tests, app build and bundle checks
```

Builds use an Apple Development signing identity when available, or ad-hoc signing.
Use `SIGN_IDENTITY=- make check` for an ad-hoc build. Tests use synthetic fixtures;
model downloads and cleanup-service installation are explicit actions in Settings.
See the [evaluation protocol](Resources/EVALUATION.md) for optional model accuracy,
seam-latency and physical release-to-visible checks.

To package a local preview after `make check`:

```sh
python3 scripts/package-release.py --version 0.1.0 --channel preview
```

For a notarized build, set `SIGN_IDENTITY` to your Developer ID Application identity and
`DISTRIBUTION_SIGNING=1` when building, then package with `--channel notarized
--notary-profile YOUR_KEYCHAIN_PROFILE`. Use a fresh output directory via
`--output-directory` for each release.

### App updates from GitHub Releases

The app uses [Sparkle](https://sparkle-project.org/documentation/) to download a release
DMG, verify its signature, replace the installed app and relaunch. Users choose when to
install; relaunch waits for active dictation to finish. Models, settings and history live
outside the app bundle and are retained. Existing versions need one manual update to a
build containing Sparkle. Normal builds include the official public signing key and
feed URL; no environment variables are required to enable the update controls.
Published updates are listed in the signed feed at the configured URL.

The release signing key is stored in the release Mac's login Keychain under the
`com.hedworth.whispr-lite` account. Only the public key is committed to the repository.
Back up the private key securely and keep the same key across releases. To publish:

```sh
APP_VERSION=0.1.0 APP_BUILD_NUMBER=6 make build
python3 scripts/package-release.py --version 0.1.0-beta.5 --channel preview \
  --output-directory dist/releases/0.1.0-beta.5
```

Forks should generate their own signing key once and override **both** the public key
and feed URL when building, rather than using the official update stream:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account YOUR_ACCOUNT
export SPARKLE_PUBLIC_ED_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account YOUR_ACCOUNT -p)"
export SPARKLE_FEED_URL=https://YOUR_HOST/appcast.xml
APP_VERSION=0.1.0 APP_BUILD_NUMBER=6 make build
```

Use a strictly increasing `APP_BUILD_NUMBER` for **every** release, including betas;
Sparkle compares this number, not the GitHub tag. For public distribution, use the
Developer ID/notarized build steps above. Preview signatures may require granting
macOS permissions again after an update.

Packaging verifies the Keychain key matches the app, then generates a signed
`appcast.xml` pointing at the exact DMG in GitHub release `v<VERSION>`. Upload the
release assets first, then publish the generated XML unchanged at `SPARKLE_FEED_URL`
(for official builds, replace `appcast.xml` in the repository root on `main`). Publishing is
a separate step; packaging never pushes or creates a release. Both the feed and the
DMG are signed, and the app verifies the download before extraction.

The feed is curated: only releases whose generated feed you publish are offered,
including GitHub prereleases. For a stable-only stream, publish only stable versions
to that feed. Each generated feed contains one release; retain separate feeds if you
later need parallel beta channels or older macOS support. Do not use GitHub's
`releases/latest` feed URL for a beta stream, since it excludes prereleases.

## License

[MIT](LICENSE). Dependencies and downloaded models have their own licences; see
[third-party notices](THIRD_PARTY_NOTICES.md).
