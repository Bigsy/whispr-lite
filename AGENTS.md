# Whispr Lite

Native macOS push-to-talk dictation app for Apple Silicon, using Swift 6.2+,
AppKit/SwiftUI, local ParakeetCore ASR and a separate local Gemma cleanup service.
Read `DEVELOPMENT.md` for setup and `CHECKS.md` for evidence and open validation gates.
Completed implementation details belong in the development guide; measured results and
remaining gates belong in the checks.

## Product and UI

- Keep common settings short and readable. Put service URLs, deadlines, custom prompts,
  model paths and development/demo controls behind clearly labeled advanced sections.
- Use a scrollable settings layout with a sensible minimum window size. Wrap help/error
  text and verify compact and full-size native renders after layout changes.
- Show recording, processing and recoverable failure clearly. Recording indicators must
  not activate the app, steal keyboard focus or appear in screenshots of private text.
- OpenWhispr can inform behavior and visuals. Check the upstream license, record the
  revision and preserve required notices if copying source. Prefer a small native
  implementation over importing Electron or a general-purpose framework.
- Demo output must remain explicitly labeled. Never silently substitute fabricated text
  for an unavailable model or failed service.

## Performance and ownership

- Keep audio/event-tap callbacks bounded: no inference, network, disk I/O, UI updates,
  unbounded allocation or waiting. Move owned audio to the existing serial workers.
- Prefer state-driven indicators. No idle animation timer, polling loop or waveform
  rendering without a measured need; cancel any active-only work when recording ends.
- Preserve generation/session ownership, ordered audio, bounded buffers, one finalizer,
  final-only insertion and suppression of late results after cancellation.
- CoreML may continue after task cancellation. Settle library ownership before reusing
  an engine for mode changes or retained-audio fallback.
- Preserve target validation, keyboard-layout-aware paste and clipboard ownership.
  Do not add arbitrary delays to the visible-text path.

## Dependencies, data and services

* Consume ParakeetCore through SwiftPM; pin a tested published version and retain
  `Package.resolved`. Keep resources and third-party licenses in the signed app bundle.

* That project is available locally here /Users/hedworth/workspace/mystuff/mac/parakeet-ane-server and can be modified freely from this project we careful not to break the current interface as it is publically available

* Keep prompts, dictionaries and settings private. Do not persist or log personal audio,
  dictation, clipboard contents or media titles. Use synthetic fixtures for checks.

* Keep model weights, build products and raw benchmark results out of source control.

* Do not replace existing services, shared caches or OpenWhispr settings as a side effect
  of building/testing. Service installation and migration must be explicit task scope.

## Validation

- `make test`: Swift tests plus native broker process and synthetic setup tests.
- `make check`: tests, arm64 signed app, doctor and bundle/resource smoke check.
- Native pasteboard tests and signing may need normal session/keychain access when the
  execution sandbox restricts them; use the permitted escalation rather than weakening
  the check or silently skipping it.
- For real ASR changes, run the synthetic batch/streaming commands in `DEVELOPMENT.md`
  against cached models. Avoid repeating expensive model benchmarks for UI-only edits.
- Record what actually passed and leave hardware/player/accuracy/performance gates open
  until measured. ASR-only or synthetic timings are not release-to-visible-text latency.
