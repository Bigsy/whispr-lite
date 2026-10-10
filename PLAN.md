# Whispr Lite — remaining work

Updated: 10 October 2026. The native app and published ParakeetCore integration exist;
this is the work needed to make the app a dependable replacement for OpenWhispr.
Implementation/setup details live in [DEVELOPMENT.md](DEVELOPMENT.md), measured evidence
in [CHECKS.md](CHECKS.md), and working conventions in [AGENTS.md](AGENTS.md).

## Current baseline

- Native Apple Silicon/macOS 14+ app; Swift 6.2+, AppKit/SwiftUI, no Electron runtime.
- ParakeetCore exact 0.2.0 through SwiftPM with `Package.resolved`; direct local Unified
  batch ASR is the default for new settings. Saved HTTP settings remain selectable.
- 68 Swift tests, 14 native broker tests, 14 setup tests and 4 release-tooling tests pass. Six synthetic batch fixtures have
  180 warm observations; signed-bundle model preparation, cancellation/reuse and unload pass.
- The real streaming adapter is exercised by the bench. Five of six fixtures have equal
  normalized words to batch; the long fixture differs. Normal app dictation remains batch.
- The pinned Gemma + MTP cleanup service is installed on 11436. OpenWhispr 1.8.3's prompt,
  188-entry dictionary and transcript framing were imported privately. Ollama remains on
  11434; optional HTTP ASR on 11435 is absent. Keep OpenWhispr available during validation.
- Signed native PCM → Parakeet → Gemma → NSTextView insertion passes: six synthetic
  fixtures, 180 warm observations. This excludes physical capture/release and other apps.
  Longer speech misses the batch latency target; see CHECKS.md for stage measurements.

## Settings and recording feedback

- [x] Add project-specific `AGENTS.md`, including native UI and performance constraints.
- [x] Separate settings into General, Cleanup and Advanced; scroll long content, wrap
  help/errors, keep the save action visible and enforce a usable minimum window size.
- [x] Show only relevant model/service controls; label demo output explicitly. Preserve
  saved alternative/custom hotkeys when changing unrelated options.
- [x] Add a saved speech-model picker for Unified, Ultra, TDT v2 and TDT v3, preserving
  Unified for existing settings. Prepare the selected batch model before recording,
  release the previous model safely and include the choice only in debug configuration.
- [x] Run a small Unified/Ultra comparison: three synthetic clips, 30 warm observations
  each, plus empty/silence, cancellation/reuse and unload/reprepare checks. Verify the
  Ultra download and add it to the owned cache; retain Unified as default. See CHECKS.md
  for timings, the observed article substitution and the limited accuracy scope.
- [x] Add a native shortcut recorder that captures a held key or combination, including
  distinct Left/Right Control. Pause dictation while choosing; wait for release, preserve
  ordinary shortcuts, cancel on Escape/focus loss and apply only when saved.
- [x] Add a compact recording/processing/error indicator and clear menu-bar symbols.
  Adapt OpenWhispr's behavior with a native implementation: no focus activation, idle
  polling/animation timer, Electron dependency or provisional-text insertion.
- [x] Reduce the listening pill and add optional noise-gated audio-level feedback. Reuse
  converted PCM, keep updates to the small wave at 10 Hz while recording, and measure
  synthetic worker/drawing cost. This visual feedback does not gate audio or use ML VAD.
- [x] Add opt-in private debug timing logs with bounded off-thread writes, rotation,
  paste-check reasons and media state/replies. Include a local summary command.
- [x] Gate timing collection on debug mode, including first-audio timestamps, pipeline
  timing callbacks and extra media ownership events. Explicit benchmarks opt in.
- [x] Verify compact/full-size native renders, light/dark appearance and indicator states.
  Synthetic native renders pass; real focus/accessibility acceptance is separate below.
- [x] Fix the Swift 6 audio-callback isolation crash; regression-check off-thread callback
  and source-buffer reuse. Invalidate preparation on lock/sleep/session loss; verified
  signed startup at the lock screen stays paused with no ready pipeline or event tap.
- [ ] Verify the floating indicator preserves focus across Spaces/full-screen/multiple
  displays; check VoiceOver, cancel/copy actions and sleep/lock behavior on real hardware.

## 1. Make the complete batch flow usable

- [x] Export installed OpenWhispr's cleanup prompt, dictionary and request framing without
  changing its settings or reading history. Keep private contents local; use its exact
  dictionary suffix, language instructions and transcript tags in the app.
- [x] Provide a general cleanup default and a settings action to load it before saving;
  keep personal context optional and preserve existing private overrides. Compare the
  default with the saved prompt on 18 synthetic cases and 720 real cleanup observations,
  separating reused prefixes from prompt-cache-disabled evaluation. See CHECKS.md.
- [x] Diagnose dictionary transmission versus actual spelling correction. Add explicit
  whole-phrase conversions (`spoken phrase > Written phrase`) after cleanup; preserve
  ordinary vocabulary and private overrides, with no extra inference or callback work.
- [ ] Review/freeze synthetic expected outputs. The installed provider differs from the
  historical tuned stack, so historical output parity remains unverified. The 512-token
  app cap matches the installed reference's larger output budget on 24 synthetic inputs.
- [x] Install/configure the existing Gemma 4 E2B QAT model and matching QAT MTP drafter.
  Preserve the development guide's tuning: draft length 6, `--swa-full`, one 4096-token slot,
  flash attention, `mmap+mlock`, reasoning off, temperature zero and Metal residency.
- [x] Pin/test the llama.cpp build and flags; record full model hashes/file sizes and
  resumable/checksum-verified downloads. Fail clearly for an incompatible binary.
- [x] Provision the official standalone macOS ARM64 cleanup release with archive/runtime
  checksums, safe staged extraction and retained licenses. Use the same v0.4.0 revision;
  verify Gemma/MTP startup and equality on 24 synthetic inputs before switching services.
- [x] Add explicit service setup/LaunchAgent and uninstall paths that preserve models
  and preferences. Handle the Ollama port conflict and asynchronous launchctl teardown;
  building/testing must not replace an existing service or login item.
- [x] Run synthetic PCM → Parakeet → Gemma → native text update/draw, with empty/silent
  input and six short/correction/dictionary/paused/long fixtures. Verify repeat equality,
  imported request framing and exact templated context-budget rejection.
- [x] Use hardware modifier state for the bounded insertion guard and inject generic
  Command-V at the session level. Cover release, held keys, cancellation and injected
  events; log hardware/session modifier categories only in debug mode. A real missing
  insertion was blocked by the old guard; confirmation after this change remains below.
- [ ] Validate real speech, dictionary accuracy, soft input and final words through physical
  capture and the destination matrix. Native synthetic insertion is only one destination.
- [ ] Finish first-use ASR downloads/default cache validation and a fresh-machine installer.
  Configured offline caches, signed-app incomplete/corrupt compiled-model errors and
  native readiness after granted permissions are checked.
  The standalone cleanup release declares macOS 13.3 minimum. End-to-end macOS 14+
  provisioning, notarization and other-machine installation remain unverified.

## 2. Finish production media recovery

- [ ] Choose the production backend using real compatibility and resource evidence.
  The persistent system-Perl broker is implemented; direct in-process access is unproven.
- [x] Add bounded automatic recovery after helper failure. A new helper generation must
  invalidate stale replies/leases; never replay an ambiguous old resume command.
- [x] Cover permission/fatal replies, slow readers, malformed/oversized output and restart
  with Swift tests launching real synthetic helper processes. Keep the native ledger/
  pipe tests. Disable incompatible control for the run without blocking ASR.
- [x] Normalize Objective-C numeric booleans at the media protocol boundary; the real
  provider's `known: 1` previously caused strict decoding to disable media for the run.
- [x] Log specific media ownership/skip reasons in debug mode. A real Spotify session
  confirmed pause but skipped resume; its retest identified `itemChanged` after Pause
  with no user playback/track change.
- [x] Tolerate opaque identifier refresh when the same player/process and bounded track
  metadata still match. Keep comparisons in helper RAM and out of protocol/log data;
  regression-check actual metadata changes and missing/invalid metadata. The user reports
  Spotify working; logs confirm three resumes and one unconfirmed resume in four pauses.
  The complete player matrix remains below.
- [ ] Verify Music, Spotify and Safari/Chromium video: playing/paused/absent, rapid release,
  cancel, silence, capture error, safety ceiling, user playback changes, track/tab/process
  changes, player quit, helper failure, setting disable and application shutdown.
- [x] Preserve explicit Pause/Play and conservative ownership: resume only a confirmed
  pause of the same identifiable playback session; skip unknown/ambiguous state. Release
  media after capture stops, independently of ASR/cleanup. Never use play/pause Toggle.
- [ ] Measure observed pause/resume, not command submission. Run at least 30 cycles per
  player; compare startup, command latency, focus, footprint and idle CPU/wakeups/power.
  Initial goals: pause/resume p95 <100 ms once ready, helper footprint <30 MiB and no
  measurable release-to-text regression. Report results rather than assuming compliance.

## 3. Run the hardware and destination matrix

| Area | Required cases |
|---|---|
| Hotkey | Recorded Left/Right Control and other modifiers, Globe/Fn, Fn+Arrow/function shortcuts, Control-Space, Control-Option-Space, custom chords, repeats, busy presses, Escape and held modifiers. |
| Capture | Built-in and used USB/Bluetooth microphones; removal/format changes; 16/44.1/48 kHz; warm/on-demand onset and final-word preservation; ceiling; sleep/wake/lock. |
| Permissions | First grant, denial, revocation, re-sign/relaunch and readiness recovery for microphone, Accessibility and Input Monitoring. |
| Insertion | Native benchmark, Notes/TextEdit, browser editor, Electron/Claude/Cowork, code editor and terminals; secure/readonly/unfocused/changed/slow destinations. |
| Keyboard layout | Normal and non-QWERTY layouts; command-modified paste mapping; physical modifiers held during insertion. |
| Clipboard | Text/rich text/image/multi-item; promised/oversized data; user copy during restore; consecutive transactions; unsupported destination. |
| Services | Cold/warm/long idle/memory pressure; unavailable or wrong service/model/alias; timeout/cancellation; port conflict. |
| Content | Subsecond speech, soft voice, silence/background music, final word, pauses, corrections, names/dictionary terms and context limit. |

- [ ] Record evidence for every applicable row. An event posted, helper reply or synthetic
  render does not prove actual text visibility, playback effect or physical onset timing.
- [ ] Confirm errors offer Copy safely; cancellation/late results never insert, overwrite
  a later clipboard copy or resume playback owned by another session.

## 4. Measure and trial the batch release

- [x] Add checked Apple Silicon preview artifacts and a tag/manual release pipeline:
  allowlisted app/setup ZIPs, version/commit/checksums, archive smoke check and draft releases.
  Stable tags require Developer ID/hardened runtime/notarization instead of falling back.
- [x] Exercise both hosted workflows and create the first `v0.1.0-beta.1` draft prerelease.
  Full checks, archive verification and uploaded asset/manifest checksums pass from the
  clean tagged commit; no model downloads, private settings or service installation in CI.
- [ ] Configure distribution credentials and pass actual notarization plus another-Mac
  installation. The separate cleanup kit still needs Python; native first-run setup is open.

- [ ] Measure real release-to-visible-text, with separate capture drain, ASR, cleanup,
  result-to-insertion and clipboard restoration spans. Use monotonic/session timing.
- [ ] Collect at least 30 warm observations per condition, raw samples and median/p90/p95.
  Interleave comparisons; report 90-second, 5-minute and ~25-minute idle trials separately.
- [ ] Include realistic memory pressure, swap/physical footprint, idle CPU/wakeups/power
  and warm versus on-demand capture. Isolated ASR timings are not whole-app latency.
- [ ] Investigate misses against the ~300–550 ms warm batch target. Verify several
  days of daily use: clipped/lost words, cleanup, insertion, media ownership and battery use.
- [ ] Verify the installed signed app/resources, first-run setup and rollback to HTTP or
  OpenWhispr. Remove OpenWhispr/login startup only as an explicit migration after acceptance.

## 5. Streaming and prefill — after the batch release

- [ ] Review accuracy/disagreement on real consented dictations and synthetic ground truth,
  especially short speech, corrections, long pauses and the long-fixture difference.
- [ ] Validate paced capture, partial lag, residual finish, cancellation races, repeated
  reset, mode switches and retained-audio fallback in the app; never split context with VAD.
- [ ] Measure streaming compute/energy/residency and batch fallback load time. Avoid
  unnecessary simultaneously loaded models in the app/server; a shared cache is not shared RAM.
- [ ] Enable real streaming UI only after accuracy/resource acceptance. Keep batch selectable
  and accept one authoritative final result; provisional text must never be inserted.
- [ ] Establish the pinned llama-server's supported prompt-evaluation path. Verify exact
  Gemma template/prefix/token compatibility, `n_predict: 0`, cache reuse and request settings.
- [ ] Connect the existing coalesced prefill scheduler to the single cleanup slot: one
  request at a time, changed useful snapshots only, at most one per 500 ms initially;
  settle/cancel in-flight prefill before final generation and bound context/deadlines.
- [ ] Verify output parity, contention and end-to-end gain over batch/no-prefill. Phase 2
  goals are ~200–300 ms long and ~200 ms short release-to-visible text; keep the faster,
  dependable mode as default if measurements do not support streaming.

## Release rule

The project is done when the complete batch flow passes the hardware/player matrix,
measured daily-use acceptance and explicit installation/rollback checks. Streaming and
prefill remain a separate later release. Re-run relevant checks after OS, library,
llama.cpp or media-adapter updates; change one component at a time.
