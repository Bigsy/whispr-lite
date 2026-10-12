# Whispr Lite

A native macOS menu bar app for local push-to-talk dictation. Hold your shortcut, speak,
and release to insert cleaned-up text into the field you're using.

Speech recognition runs inside the app using **ParakeetCore**, with Parakeet Unified
0.6B selected by default. A separate local **Gemma 4 E2B QAT** service cleans up the transcript, with
MTP speculative decoding. Dictation runs on your Apple Silicon Mac without a cloud service.

## What it does

- **Your own hold shortcut.** Record a key or combination, including Left or Right Control.
- **Speech-model choice.** Select Unified, Ultra, TDT v2 or TDT v3 in General; missing
  models can be downloaded before recording.
- **Clear recording feedback.** A small floating pill shows listening and processing,
  with optional microphone-level feedback.
- **Custom cleanup.** Start with the general default prompt, add your own context, and
  use a private dictionary for names and technical terms. Add exact phrase conversions
  such as `spoken phrase > Written phrase`, one per line.
- **Paste where you're working.** Uses the current keyboard layout and restores the
  previous clipboard if you haven't changed it in the meantime.
- **Optional media control.** Pauses supported active media while recording and resumes
  playback it paused when recording ends.
- **Cancel and recover.** Press Escape to cancel; use **Copy last result** if insertion fails.
- **Opt-in diagnostics.** Debug logs record timings, readiness, paste checks and media
  outcomes without recording audio or dictated text. Extra timing instrumentation is
  disabled outside debug mode.

The app is built with Swift, AppKit and SwiftUI. It uses no Electron runtime.

## Getting started

Prebuilt apps are produced by the repository's **Checks** workflow. Version tags
produce draft [GitHub releases](https://github.com/Bigsy/whispr-lite/releases) with a DMG
(drag the app onto Applications), the same app as a ZIP, and a separate cleanup setup kit.
See the [download installation guide](Resources/RELEASE-INSTALL.md) for setup without compiling.

> **Preview builds are not notarized.** macOS blocks their first launch ("Apple could not
> verify…"). After copying the app to Applications, either open it once and click
> **Open Anyway** in System Settings → Privacy & Security, or clear the quarantine flag:
>
> ```sh
> xattr -dr com.apple.quarantine "/Applications/Whispr Lite.app"
> ```
>
> Preview builds are also ad-hoc signed, so macOS asks again for Microphone, Accessibility
> and Input Monitoring after each update. If a permission looks enabled but does not work,
> remove the app from that list with **−** and add it again. Apps built locally with
> `make build` are not quarantined.

Requires **Apple Silicon**, **macOS 14 or later**, **Swift 6.2+** to build, and **Python 3.9+**
for the cleanup setup scripts.

1. Follow the [local cleanup setup](DEVELOPMENT.md#local-cleanup-setup-and-private-migration)
   to install the models and service. It uses a checksum-verified standalone llama.cpp
   release on `127.0.0.1:11436`; Homebrew is not required.
2. Build and open the app:

   ```sh
   make build
   open 'dist/Whispr Lite.app'
   ```

3. In **Settings → General**, grant Microphone, Accessibility and Input Monitoring
   permissions, then record your hold shortcut.
4. In **Advanced**, choose an existing ASR model cache or enable downloads of missing
   models. Save settings and click **Check readiness**. Once ready, focus a text field,
   hold your shortcut and speak.

`make install` copies the app to `/Applications` (an admin account is needed; set
`APP_INSTALL_DIR=~/Applications` for a per-user install); model/service setup is separate.
The [development guide](DEVELOPMENT.md) also covers an existing local HTTP ASR backend,
explicit demo mode and optional private import from OpenWhispr.

## Privacy and microphone

Audio is processed locally and is never saved. **Keep dictation history on this Mac**
(Settings → Cleanup, on by default) saves each transcript and its cleaned text to a private
file in `~/Library/Application Support/WhisprLite/History`, so a better local cleanup model
can later be trained on your own dictation. It never leaves your Mac, is excluded from Time
Machine, keeps at most 32 MB and can be turned off or deleted at any time. Prompts,
dictionaries and settings stay in your private application-support folder. Debug logging
is off by default.

**Keep the microphone ready** maintains a 150 ms rolling buffer in memory and shows the
macOS microphone indicator. Turn it off to start capture only when you press the shortcut.

## Current status

Batch dictation is implemented and in use. Compatibility across apps, microphones and
media players, daily-use performance and fresh-machine installation are still being
validated. The app is not yet notarized. Real streaming is available in the development
bench; normal dictation uses batch recognition.

## Development

```sh
make test    # Swift, media-broker and setup tests
make check   # Tests, signed app build, doctor and bundle smoke check
```

- [Development guide](DEVELOPMENT.md): setup, configuration and benchmarks.
- [Checks](CHECKS.md): measured results and remaining validation.
- [Historical notes](bench/HISTORICAL_NOTES.md): original OpenWhispr stack experiments.
- [Third-party notices](THIRD_PARTY_NOTICES.md): dependencies and behavioral references.

## License

Whispr Lite is [MIT](LICENSE) licensed. Dependencies, the vendored media adapter and the
downloaded models keep their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
