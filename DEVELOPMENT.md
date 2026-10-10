# Development and validation

The native app consumes the published ParakeetCore 0.2.0 Swift package. It is not a validated
replacement for OpenWhispr yet. A configured local stack and private import from installed
OpenWhispr 1.8.3 are available on the development machine. Synthetic native integration
passes; physical capture, other destinations, playback and daily-use acceptance remain open.

## Build and run

Requires Apple Silicon, macOS 14+ and Swift 6.2. `make build` assembles
`dist/Whispr Lite.app`; open it with `open 'dist/Whispr Lite.app'`. Build/test do not install,
restart or reconfigure model services or login items. The app's SwiftPM dependency is
ParakeetCore, pinned to exact 0.2.0 with `Package.resolved` retained.
New settings default to direct local Unified ASR, with real Gemma
cleanup. Select **DEMO** explicitly in Settings to test fabricated output without services;
demo bypasses real ASR and cleanup and remains visibly marked. Demo streaming is optional.
Saved HTTP settings remain HTTP. For local ASR, select a complete model cache in Settings,
or enable **Download missing ASR models when preparing** before saving. Downloads are off
by default. A blank cache path uses `~/Library/Application Support/FluidAudio/Models`.
Preparation shows cache/load/warm-up/download stages and explicit library errors.

Settings are split into **General**, **Cleanup** and **Advanced**. General holds recording,
microphone, media and permission controls; Cleanup holds the private prompt/dictionary;
Advanced holds relevant model paths/downloads, local service URLs, deadlines and explicit
demo controls. Help/errors wrap, content scrolls and the save action remains visible at
the minimum window size. Saving unrelated settings preserves custom hotkey configurations.

Cleanup's **Use default prompt** replaces only the editor text; **Save settings** applies
it. The general default makes minimal edits, preserves meaning and uncertainty, treats
questions/commands as dictated content, handles self-corrections and uses British spelling
for English. Add a brief context line for your own work or terminology, conditional on the
dictation's context. Fresh installs have an empty dictionary. Saved custom prompts remain
private and take precedence over the default.

The dictionary accepts ordinary preferred spellings and explicit phrase conversions,
one rule per line: `happy fire > HAPI FHIR` or `dochler > Doccla`. `=>` is also accepted.
Plain entries are guidance to Gemma, not guaranteed ASR biasing. Exact conversions run
once after a successful cleanup, case-insensitively on whole words/phrases; the right side
keeps its chosen spelling/case. Longer overlapping phrases take precedence. Rules never
cascade, regex characters are literal, and conflicting spellings for the same alias are
ignored. Unrelated words such as “doctor” are untouched. Parsing/regex compilation happens
when preparing settings, with no audio callback work, extra inference or timing collection.
`whispr-bench --dictionary-check` runs five synthetic inputs through the actual saved
cleanup configuration (requires the private Doccla conversion); the HAPI FHIR rule is
added in RAM for that check. It records only the pass count, never private text or outputs.

A compact native floating pill shows Listening, Processing, Inserting or a recoverable
error with Copy when text is available. It uses a nonactivating panel, hides when idle,
and never displays transcript text. Its status updates on lifecycle changes; the optional
audio-level wave runs only while recording, with no idle timer, polling or capture-thread
UI work. Full-screen/Spaces/multi-display
focus and accessibility acceptance still need the manual matrix.

Open the settings directly with `open 'dist/Whispr Lite.app' --args --settings`.
`WhisprLite --ui-preview OUTPUT_DIRECTORY` renders synthetic native settings in compact/
full sizes and light/dark appearances plus indicator states. It starts no hotkey, audio,
model or service, and reads/writes no real settings. Preview images are not a focus or
visible-insertion acceptance test.

The build finds an existing Apple Development identity, or uses ad-hoc signing if none
exists. Override with `SIGN_IDENTITY='Apple Development: …'` or `SIGN_IDENTITY=-`. Keychain
signing needs access from the invoking process; a sandboxed build may need the signing
step run with that access. Ad-hoc/repeatedly changing signatures may invalidate macOS
permission grants. This build is not notarized and does not configure login startup.

## Release pipeline

`.github/workflows/ci.yml` runs `make check` on main/PRs and provides downloadable preview
ZIPs as Actions artifacts. `.github/workflows/release.yml` runs on `v*` tags or manually.
Both use the Apple Silicon `macos-15` runner and Xcode 26.0.1 (Swift 6.2), with commit-pinned
checkout/upload actions. No model downloads, ASR benchmarks or service installation run in CI.

Tags such as `v0.1.0-beta.1` produce an explicitly named, ad-hoc-signed preview and a
draft prerelease. Stable tags such as `v0.1.0` require Developer ID/hardened-runtime signing
and accepted Apple notarization; missing credentials fail instead of silently producing
an unsigned stable release. Every tagged release stays a draft for installation review.
Manual runs produce artifacts without creating a tag/release. Only tag runs have the final
draft-release step; no pipeline automatically publishes a release.

Configure these repository **Actions secrets** for the notarized channel:

- `DEVELOPER_ID_P12_BASE64`: exported Developer ID Application certificate/private key, Base64 encoded.
- `DEVELOPER_ID_P12_PASSWORD`: the exported P12 password.
- `ASC_PRIVATE_KEY`: App Store Connect team API key's P8 contents.
- `ASC_KEY_ID` and `ASC_ISSUER_ID`: matching team API key identifiers.

The release runner imports the certificate into a temporary keychain and removes it and
the P8 file in an always-run cleanup step. No personal development certificate is exported.
`build-app.sh` supports `APP_VERSION`, `APP_BUILD_NUMBER`, `SIGN_KEYCHAIN` and
`DISTRIBUTION_SIGNING=1`. The app gets the audio-input hardened-runtime entitlement;
the bundled framework is signed before the app. Distribution acceptance remains unmeasured
until actual credentials are configured and notarization succeeds.

For a local preview after `make check`:

```sh
python3 scripts/package-release.py --version 0.1.0 --channel preview
```

For a notarized local build, set the matching numeric `APP_VERSION`, a Developer ID
`SIGN_IDENTITY` and `DISTRIBUTION_SIGNING=1` when running `make check`, then package with
`--channel notarized --notary-profile YOUR_KEYCHAIN_PROFILE`. Use an empty output directory
for each invocation; existing assets are never overwritten.

Packaging validates the bundle version/arm64 signature, notarizes and staples when requested,
then extracts the actual final ZIP and repeats signing/resource smoke checks. Outputs are an
app ZIP, allowlisted cleanup setup ZIP, version/commit/hash manifest and SHA256SUMS. The kit
contains only the existing setup script, pinned public asset lock and installation guide;
it still requires Python 3.9+. Models, personal settings/dictionaries/prompts and raw results
are excluded. Native first-run cleanup provisioning and another-Mac installation remain open.

References: [GitHub runner image/toolchain inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md),
[GitHub certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
and [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The menu exposes microphone, Accessibility and Input Monitoring guidance. It requests
microphone permission only from the explicit menu action. After granting permissions,
select **Check readiness**. The default shortcut is standalone Globe/Fn; Control-Space
and Control-Option-Space are offered. A versioned private config can also specify another
macOS key code/modifier combination or a modifier-only chord. Fn shortcuts cancel the
recording and pass through. Configure macOS's own Globe action if it conflicts; verify
real hardware events in the release matrix.

In **General → Hold shortcut**, select **Record…**, press and release your key or
combination, then **Save settings**. Bare Left/Right Control, Shift, Option and Command
retain their physical side; Globe/Fn and regular key combinations are supported too.
The sheet pauses dictation, captures only its local key-window events and removes its
monitor on dismissal. Escape, Cancel or losing focus discards the candidate. Caps Lock
is a toggle and is rejected as a hold key. For a standalone modifier, adding another
modifier or typing an ordinary shortcut cancels dictation and passes that shortcut
through; releasing a configured chord finishes once, in either release order.

While recording, a focus-preserving **Listening** pill appears near the bottom of the
screen containing the pointer. It changes to **Processing** after release and hides on
completion. The normal window is 238×64 points; longer recoverable errors retain more
space. General's **Show audio activity in the listening pill** controls a noise-gated
microphone-level wave. It measures the existing converted PCM on the serial audio worker,
updates only the small wave at up to 10 Hz during recording, and stops on release/cancel/
lock. It performs no ML voice detection, segmentation or audio filtering. A flat line
means quiet input, and loud non-speech sound can also move the line.

If holding the saved shortcut does nothing, check the General readiness
status first: the global shortcut is installed only after ASR, cleanup and permissions
are ready. With downloads disabled, the selected cache must contain complete Unified
models; a blank path requires the default FluidAudio cache. The cleanup service must
also be running at the saved endpoint.

In **Advanced → Diagnostics**, enable **Record debug timings** and save. Use **Show logs
in Finder** to open `~/Library/Application Support/WhisprLite/Diagnostics`. Logging is
off by default. Records include run/session IDs, monotonic stage times, preparation/
permissions, paste-validation reasons, clipboard-restoration outcome and media command/
reply state. Insertion includes hardware/session modifier categories and the physical
release wait, so synthetic state can be distinguished from a key still held. Media replies
include fixed reasons for player/track/process changes,
external playback, missing pause ownership and failed confirmation. No identifying
metadata is logged. The writer runs on a utility queue with at most 128 pending events and two
2 MiB JSONL files. Disable logging and save to stop new records; existing logs remain for
inspection. Audio, transcript/prompt/dictionary/clipboard contents, media identifiers/
titles, arbitrary errors, URLs and user file paths cannot be included in the typed schema.
Timing collection is also disabled by default: no stage clock reads/event accumulation,
ASR/cleanup timing callbacks, first-audio diagnostic timestamp or clipboard diagnostic
callback in normal mode. Insertion's extra session-state query and modifier record are
debug-only; clear hardware state requires no release-wait clock read or sleep. The media
helper enables extra ownership-reason events only
for a debug run. Capture timestamps needed for correct release trimming and operation
deadlines remain active independently of diagnostics. Explicit benchmark commands opt in.

An `itemIdentifierRefreshed` media reason means the player changed its opaque identifier
while the same bounded content metadata still matched. That refresh keeps the pause
session eligible for one resume. Content, player/process or observed playback changes
still invalidate it. Metadata is retained only in helper memory and excluded from replies
and logs; missing metadata keeps the strict identifier check.

```sh
python3 scripts/analyze-diagnostics.py
```

The summary reports capture-drain, ASR, cleanup, insertion-dispatch and clipboard spans
plus failure/media state and skip-reason counts. It also reports request-to-confirmation
media pause/resume spans and Play submission separately; confirmations are helper state
observations, not measured acoustic output. `firstAudio` is the first converted recording buffer's
worker timestamp, reported after capture drains. Generic Command-V posting is measured
as dispatch, not proven text visibility in Ghostty/other apps. The controlled native
benchmark remains the only source of actual native text-update timing. For performance
checks, `WHISPR_FEEDBACK_BENCHMARK_PATH=/absolute/output.json swift test --filter
AudioActivityTests.optionalSyntheticWorkerBenchmark` exercises synthetic conversion;
`--ui-preview` also writes `activity-draw-cost.json` for offscreen synthetic CPU drawing.

Warm capture keeps only 150 ms of idle audio in RAM and shows the microphone indicator.
On-demand mode starts on press. Capture uses the hardware format, a fixed input slot
pool, serial conversion and bounded 16 kHz PCM. **Low-latency capture** (Advanced, on by
default) connects the input node to an `AVAudioSinkNode`, which delivers each hardware
I/O cycle (512 frames, 11.6 ms, at 44.1 kHz on this Mac) on the real-time thread: 128 slots
of at least 50 ms each. Turning it off uses the former input tap, which delivers 100 to
400 ms packets whatever size is requested (4,410 frames at 44.1 kHz here): 16 slots of
0.4 s at the hardware rate (minimum 8,192 frames); 96 and 192 kHz devices fit. The
callback claims slots in order through a counting semaphore and the serial worker returns
them in the same order, so the callback never takes a lock. Release waits for the packet
containing the accepted release boundary, trims it and drains the converter once. If that
packet is late (about 100 ms beyond the last packet's duration, 0.15 to 0.5 s), the
recording is kept without the unseen tail and debug diagnostics record `capture/drainTimeout`.
Capture starts before the AX target snapshot, and AX calls into the target are bounded to
1 s each; insertion validation reads its four attributes in one AX round trip.
A microphone route change (for example AirPods becoming the default input) rebuilds only
capture after 500 ms; more than three changes in 30 s asks for a readiness check. A press
while dictation isn't ready shows the error pill instead of being silently swallowed.
Saving settings, wake, unlock and readiness checks reuse the prepared ASR model unless the
backend, model, cache directory, downloads or ASR endpoint changed. The 120-second
ceiling reserves a small margin for pre-roll/drain and offers a copy-only result. Exact
physical-event/onset behavior, Bluetooth routing and power use still need hardware tests.

Preferences and private `prompt.txt`/`dictionary.txt` live in
`~/Library/Application Support/WhisprLite/` (directory 0700, files 0600). The supplied prompt
is the general default; a saved prompt overrides it. The configured development profile
retains its private import until changed in Settings. Historical cleanup output parity is
not established. Service URLs
are loopback HTTP **base URLs without `/v1`**. Invalid settings fail
clearly. No dictation history, clipboard content or media titles are logged/persisted.
The last result is bounded to 32,768 characters in RAM and cleared on the next recording.

Insertion snapshots the PID/focused AX element and rechecks it after a 250 ms bounded
physical-modifier wait. This checks HID hardware state, since combined session state
also reflects synthetic events. Clear hardware state passes immediately. AX selected-range
writes are restricted to the controlled native benchmark field; other editable fields use
layout-aware Command-V from a private event source at the session tap. Both events carry
only Command and our injected-event marker. A held-key failure retains the result for Copy.
Unsupported/secure,
readonly or changed targets offer Copy. Clipboard snapshots reject promised or oversized
data and retain all materializable types/items. The dictation is written as promised
text marked `org.nspasteboard.TransientType` and `AutoGeneratedType`, so clipboard managers
skip it. The target's first read of the promise schedules the restore 100 ms later (grace
for multi-type readers); a target that never reads is restored after 1.5 s. Restore happens
only if both text and change count are still owned. The restore is never on the
visible-text path. A dispatched paste is not a measured visible update.

`make install` copies only the app into `~/Applications` (`APP_INSTALL_DIR` overrides it).
`make uninstall` removes only that app, preserving preferences/models. Neither command
changes the model services. Cleanup service setup below is explicit and separate. A complete
fresh-machine installer, notarization and other-machine provisioning validation remain pending.

## Local cleanup setup and private migration

Setup scripts require Python 3.9+. The tested server/model inventory is in
`Resources/cleanup-stack.json`: llama.cpp 0.4.0 at revision
`5266f24da75dc449bd56cbed7addb9c8e4a6a73e`, with binary/linked-library SHA-256 checks;
Gemma 4 E2B QAT UD-Q4_K_XL and matching root QAT MTP from pinned Hugging Face revision
`66a399f68ddd113b06dff02fca9523e55465d11d`. Cleanup uses the official
[b10809 macOS ARM64 release](https://github.com/ggml-org/llama.cpp/releases/tag/b10809),
the same revision as v0.4.0. Its archive and 60 runtime files have pinned SHA-256 values.
`cleanup-prepare` downloads/verifies the archive, rejects unsafe tar entries, stages the
extraction and publishes it under `Cleanup/Binaries/llama-b10809` only after verification.
The release includes its non-system libraries and LICENSE; it needs no Homebrew runtime
or global library relinking. Version/help checks and the server share an environment
that strips inherited llama argument and dynamic-loader overrides. Setup fails on
missing/changed runtime files. Mach-O minimum is macOS 13.3; the app targets 14+.
Other-machine/older-macOS installation and notarization still require validation.

```sh
make cleanup-prepare
python3 scripts/cleanup-service.py verify
make cleanup-install
make cleanup-uninstall
```

`cleanup-prepare` resumes downloads into partial files, checks exact sizes/full SHA-256
and atomically installs verified files. Defaults are under
`~/Library/Application Support/WhisprLite/Cleanup`. `cleanup-install` creates only the
owned `com.hedworth.whispr-lite.cleanup` LaunchAgent, on **127.0.0.1:11436**; it validates
before replacing an owned item, waits for launchctl and the old PID to settle, refuses
foreign items/occupied ports and rolls back failed startup. Immutable runner/lock copies
revalidate weights and binary dependencies at each launch. Uninstall preserves models,
runners and app preferences. `--directory`/`--port` can override the script defaults.
Building/testing never invokes these setup commands. The app itself has no login item.
`cleanup-uninstall` removes only the owned LaunchAgent; the release bundle, model files
and private preferences remain available for reinstall.

The server uses MTP draft length 6, `--swa-full`, one 4096-token slot, flash attention,
`mmap+mlock`, reasoning off, temperature zero and 86400-second Metal residency. Content
logging, web UI and slot persistence are disabled; launch output goes to `/dev/null`.
The alias is `gemma4-e2b-cleanup:latest`. Ollama on 11434 remains untouched. Readiness
checks both health and the exact model alias. Cleanup applies the server's exact chat
template/tokenizer before generation and rejects context overflow rather than truncating
text. Output room scales with the transcript (UTF-8 bytes / 2 + 64, between 128 and 1024
tokens), never requiring more than the former 512. Preparation records the fixed framing's
token count; when that plus the transcript's byte count and the output room fits, the
per-dictation template/tokenize round trips are skipped, otherwise the exact check runs.
Readiness waits up to about 15 s for a cleanup service that is still starting. Legacy saved preferences retain plain request
framing; imported profiles use OpenWhispr transcript tags and its dictionary suffix.

```sh
python3 scripts/export-openwhispr.py
python3 scripts/configure-local-stack.py \
  --import-directory private/openwhispr \
  --asr-cache "$HOME/Library/Application Support/WhisprLite/Models"
```

The version-checked exporter reads only whitelisted cleanup/language settings, the
installed public prompt sources and active dictionary rows. It reads neither transcription
history nor credentials, makes no writes to OpenWhispr and refuses an existing export.
`private/openwhispr` is ignored; exported files and app preferences use 0700/0600 modes.
Quit Whispr Lite before applying its profile, then reopen Settings/Check readiness.
Configuration preserves saved backend/hotkey choices, backs up existing private files
and refuses to overwrite a differing private prompt/dictionary. The chosen ASR cache must
already contain complete Unified models; this command neither downloads nor copies them.
The development profile uses an owned offline cache cloned from synthetic benchmark
assets. The default FluidAudio shared cache and OpenWhispr's profile remain untouched.

The installed 1.8.3 cleanup provider differs from the server in the
[historical notes](bench/HISTORICAL_NOTES.md).
The importer recovers its English prompt resolution, language instruction, comma-joined
188-entry dictionary and transcript framing. Controlled comparisons match all 24 synthetic
outputs between the app's 512-token cap and the reference's 4096-token minimum budget;
they do not establish historical provider parity or reviewed accuracy.

Media control uses the persistent system-Perl broker. Transient helper failures allow at
most two replacements per run, after old-process settlement. Generations discard old
replies and playback leases. Fatal/invalid protocol disables control for the run; bounded
off-main-thread writes and reads keep ASR independent. Real player/footprint/power
acceptance remains open in CHECKS.md.

## SwiftPM and real-model integration

Normal builds resolve `https://github.com/Bigsy/parakeet-ane-server.git` at exact `0.2.0`,
whose published tag points to `09873950b95b966ad8237caca1be1d604d235db6`. A sibling checkout
is unnecessary. Keep `Package.resolved` with the app to freeze transitive dependencies.
Both batch and streaming APIs are linked, while normal dictation uses batch.

General's **Speech model** picker selects Unified (default), Ultra, TDT v2 or TDT v3
when using direct Parakeet. The saved choice applies on Save; old preferences keep
Unified. All four use batch in the app. Before loading the replacement, preparation
waits for the previous setup task and unloads its engine. If cancelled CoreML inference
is still busy, preparation fails visibly and Check readiness can retry; the app does
not load a second model concurrently. Debug configuration records the fixed model enum,
with no additional recording-time instrumentation.

Each model has its own repository-named subdirectory under the selected cache root.
Enable downloads in Advanced and save to prepare an uncached choice. Missing or invalid
models fail explicitly; there is no substitution with Unified or demo output. Cleanup
still uses the pinned Gemma/MTP service independently of the speech picker.

App builds use `scripts/swiftc-app.py` to adapt SwiftPM's generated resource
accessor to `Bundle.main.resourceURL` before compilation, and stage its bundles under
`Contents/Resources`. Upstream ASR sources remain unchanged. This avoids relying on the
build-directory fallback after installation. The bundle smoke check verifies FluidAudio's
resource bundle can be opened. `WhisprLite --asr-check /absolute/path/to/Models`, from the
built app's `Contents/MacOS`, prepares real models, transcribes short silence and unloads.
An optional model argument selects another cached stack, for example
`WhisprLite --asr-check /absolute/path/to/Models ultra`.

The release bench executable accepts `--parakeet-check CACHE WAV_DIRECTORY OUTPUT_JSON`:
validated 16 kHz mono synthetic WAVs, 30 warm repetitions each, empty/silence, cancellation,
reuse and unload/reprepare. `--streaming-check` uses the same arguments and checks ordered
640-sample input, partial revisions, final text versus batch, cancellation/settlement,
batch fallback and returning to streaming. It sends audio without capture pacing and
does not measure physical partial lag, visible insertion, cleanup or ground-truth WER.

`--streaming-prototype CACHE WAV_DIRECTORY OUTPUT_JSON --repetitions 30` compares
the pinned Unified adapter with batch on the same synthetic files. It feeds 640-sample
chunks on a 40 ms capture schedule, holds the end until the audio duration, and records
first partial, append lag, finish call, residual after release and batch inference time.
Batch samples bracket the streaming block; model-mode switches and session creation are
outside the timed capture spans. It also measures a cancelled-stream-to-batch fallback
and reset. The raw JSON is ignored under `bench/results/`. Use normal GPU access, close
the running app during measurement, and do not supply private recordings. This bench
does not include microphone buffering, Gemma cleanup or visible insertion.
With `--repetitions 1`, the prototype also records synthetic partial text for a
follow-up prompt-cache mock; the 30-run report retains only partial counts and timing.
`python3 scripts/bench-partial-prefill.py --repetitions 30` reads those synthetic
snapshots and starts an isolated pinned Gemma server on 11437 with RAM prompt
restoration disabled. It compares the already warm fixed prefix with prefix plus first
partial and writes metric-only output to ignored `bench/results/partial-prefill.json`.
The installed 11436 service is untouched. Its release savings are projections from
measured partial lead time and request durations, not full pipeline observations.
`python3 scripts/bench-cleanup-roundtrips.py --repetitions 30` uses the same isolated
server and synthetic final transcripts to compare the existing exact template/token
preflight with a direct final chat request. Its direct path is only a latency mock: it
does not preserve the app's exact context-limit check. The metric-only report is ignored
at `bench/results/cleanup-roundtrips.json`.

`python3 scripts/bench-speculative-cleanup.py --repetitions 30` reads the ignored
synthetic `streaming-snapshots.json` and `speculative-snapshots.json`. To reproduce the
latter, append 2.7 seconds of silence to `bench/results/audio/short.wav` and 1.8 seconds
to `correction.wav` with `sox ... pad 0 SECONDS`, put the two files in an ignored WAV
directory, then run `--streaming-prototype CACHE WAV_DIRECTORY
bench/results/speculative-snapshots.json --repetitions 1` with the app closed. Reopen
the signed app afterward. The cleanup mock starts an isolated Gemma server on 11437,
compares full partial cleanup with final-only cleanup, and overlaps stale/final requests
on its one slot. The ignored `bench/results/speculative-cleanup.json` contains metrics
only; the installed 11436 service and private settings remain untouched. Release savings
combine separately measured partial lead and Gemma timing, so they are projections.

`--press-warmup-prototype CACHE WAV_DIRECTORY OUTPUT_JSON --repetitions 30
--idle-seconds 1` uses the same pinned batch backend for an alternating baseline versus
one 16 kHz silence inference started at synthetic press. It wakes every 40 ms during
the synthetic recording, waits for warm-up settlement at release, then measures final
ASR. It reports the extra warm-up inference and release tick lag separately. Cached
models are prepared before timed spans; the normal app should be closed for measurement.
Use only synthetic WAVs. A short idle interval is a repeated comparison, while sparse
90-second idle observations are exploratory and must be labeled as such.

Normal direct Parakeet dictation starts one batch silence inference when push-to-talk
begins at least 90 seconds after the last ASR activity. It runs on the model's worker
while the normal capture path records. There is no idle timer or periodic model ping.
The one-shot task is not cancelled while CoreML may still own the engine: release waits
for its settlement before final ASR, and settings preparation waits before unloading
the old model. Cancellation suppresses the old dictation result; an immediate retry
can await the same pending warm-up. Other ASR backends and demo mode do not warm.
This is based on a small long-idle synthetic spot check; hardware capture, power and
longer idle gates remain open in CHECKS.md.

For a small model comparison, point the batch command at a directory containing just
the desired synthetic clips. `--model` selects the speech model; downloads remain off
unless explicitly requested:

```sh
.build/arm64-apple-macosx/release/whispr-bench --parakeet-check "$PWD/.build/models" "$PWD/bench/results/model-picker-audio" "$PWD/bench/results/model-unified.json" --model unified
.build/arm64-apple-macosx/release/whispr-bench --parakeet-check "$PWD/.build/models" "$PWD/bench/results/model-picker-audio" "$PWD/bench/results/model-ultra.json" --model ultra --allow-model-downloads
```

This measures 30 warm runs per clip, with preparation/download time reported separately.
Run one model at a time, with the normal app closed and no simultaneous builds. The
explicit batch benchmark stores synthetic output for repeat comparison; never supply
personal recordings. These are ASR-only observations, not physical dictation latency or
a general accuracy ranking.

`make candidate-check` remains available for future local candidates. It archives the
committed `v0.2.0` tag from the sibling checkout by default. `PARAKEET_CORE_PATH` and
`PARAKEET_CORE_REF` override source/ref; `PARAKEET_MODEL_CACHE` selects a cached model root.
Local streaming candidates additionally use `PARAKEET_STREAMING_CANDIDATE=1`. This check
requires cached models and never substitutes fake output or downloads weights. Run a
normal `make check` afterwards to restore the published release's lockfile.

The streaming adapter waits for settlement before switching to retained-audio batch
fallback. The app exposes streaming only in demo mode pending the broader M7/M8 acceptance;
the real-model bench exercises the adapter directly. Streaming-partial prefill is not
enabled. Fixed cleanup-prefix warming now runs during app preparation (see below).

## Checks and benchmarks

- `make test`: Swift boundary/lifecycle/audio/network/clipboard/streaming tests and native
  broker process tests, plus synthetic setup/migration/download/port/rollback tests; no
  microphone permission, model downloads, real login-item writes or private input needed.
- `make build`: arm64 release app, media framework, SwiftPM resource bundles, signature verification.
- `make doctor` / `make status`: read-only toolchain, plist, signature, port and service health checks.
  Missing services are reported and do not fail the fake development check.
- `make check`: tests, build, doctor and bundle smoke check.
- `make bench`: 30 warm fake orchestration observations. Its JSON explicitly excludes real
  inference, visible insertion and performance claims.
- `make bench-media`: 30 one-shot state reads versus 30 persistent broker state reads,
  plus a native state probe. Default is read-only. `scripts/bench-media.py --cycles` performs
  30 actual pause/resume cycles on an identifiable playing player; run for each player.
  State round-trip timings are not observed playback transition timings. Physical footprint,
  focus preservation, wakeups/power and actual player compatibility remain manual gates.
- `scripts/generate-speech.py`: synthetic `say`/`afconvert` fixtures with exact 8/25-second
  containers, padded after complete speech. Voice/rate/OS, lengths and SHA-256 values are
  recorded in generated metadata; this is not a frozen ASR accuracy corpus.
- `python3 scripts/bench-stack.py --prompt-file PATH`: optional real cleanup benchmark with 24 synthetic
  inputs and 30 warm repetitions each. `--idle-seconds 90 300 1500` adds separately labeled
  idle trials. Add `--dictionary-file PATH --import-file PATH --compare-reference-budget`
  for imported framing and the controlled output-cap comparison. Private inputs/outputs
  stay in RAM; reports contain only timing/count/parity metadata. Expected outputs remain
  unset until reviewed and frozen. The default endpoint is 11436.
- `make candidate-check`: committed local dependency consumer; requires a valid ASR cache.

To compare a saved cleanup prompt with the general default on the actual local model:

```sh
python3 scripts/bench-prompts.py \
  --baseline-prompt "$HOME/Library/Application Support/WhisprLite/prompt.txt" \
  --dictionary-file "$HOME/Library/Application Support/WhisprLite/dictionary.txt"
```

The 18 synthetic prompt fixtures check content, corrections, British spelling, deliberate
emphasis, questions/instructions and dictated line breaks with a synthetic dictionary,
in plain and tagged formats. Performance uses the selected private dictionary and four
short fixtures, 30 observations per fixture/condition, interleaved blocks and an explicit
prefix warmup before each warm block. Both modes use warm model weights: **uncached**
disables prompt-cache reuse and verifies zero reused tokens; **warm** permits reuse.
The pinned [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/5266f24da75dc449bd56cbed7addb9c8e4a6a73e/tools/server/README.md)
describes this prefix reuse and the returned cache/prefill/generation counters.
Measurements include the app's template/token-budget requests and completion, plus server
prefill/generation metrics. `--import-file` preserves an imported dictionary prefix;
`--candidate-context-file` adds a private context line to a third comparison. `--quality-only`
skips performance. Reports contain metrics and synthetic case IDs, with no prompts,
dictionary contents or generated text. They exclude physical dictation, model-load cold
starts and long-idle/memory-pressure behavior. No app settings or services are changed.

Raw benchmark output lives in ignored `bench/results/`. [CHECKS.md](CHECKS.md) records the
checked revision/environment and remaining acceptance gates. Use the app's **Benchmark
text field** to timestamp actual native text updates. Cross-check third-party apps and
non-QWERTY layouts, permissions, sleep/lock, devices and all media/clipboard cases listed
in CHECKS.md. Repeated Ctrl/Fn, cancellation and rapid recording cycles need hardware testing.
Keep OpenWhispr available with a distinct shortcut; this task did not retire it or change
its services, settings or login behavior.

### Fixed-prefix prefill prototype

`scripts/bench-prefill.py` is the retained experimental harness. It reads the saved
cleanup prompt, dictionary vocabulary and framing into RAM, derives the common token
prefix from two synthetic continuations, evaluates that prefix at mock button press,
then submits a normal final chat completion at mock release. A configurable hold gives
prefill time to run; release waits if prefill has not completed. There is no microphone,
ASR, insertion, capture workload or periodic warm-up task.

```sh
python3 scripts/bench-prefill.py --isolated-server --repetitions 30 --hold-seconds 0.5
```

The temporary server uses port 11437, checksum-verified existing Gemma/MTP assets and
the installed tuning, plus `--cache-ram 0` to prevent restored full-transcript cache
entries from contaminating a fixed-prefix comparison. It is terminated on completion,
failure or interruption. It does not install a LaunchAgent or change the service on
11436. Normal Metal access is required; use permitted escalation if the sandbox denies
creation of a Metal command queue. Model loading/checksums are outside measured spans.

Four conditions alternate across three synthetic inputs (question, correction and a
longer request): forced prompt-cache miss and primed warm prefix, each with/without
prefill. A real synthetic prior cleanup primes every warm observation. Cold conditions
disable reuse on the baseline request or the prefix-preparation request respectively;
the final prefilled request enables reuse. Model weights remain loaded. Counters reject
missing prefix reuse and suspicious full-transcript hits. These controlled misses do
not simulate model loading, service restart, long idle or memory pressure.

The native token array must include BOS (`add_special: true`); otherwise the final chat
route starts with a different token and reuses none of the prepared prefix. Final
token-budget checks also include BOS. On the pinned server `n_predict: 0` still reports
one prediction and can emit text: the prototype discards it, bounds the result to one
token, and records the count/boolean without logging its contents. True zero-generation
semantics are not claimed.

Reports contain numeric timings, counts, synthetic IDs, within-condition repeatability
and paired exact/word parity; no prompt, dictionary, token arrays, input or output text.
Exact comparisons precede the app's deterministic dictionary substitutions. Reported
release time includes unfinished prefill plus template/token checks and final cleanup;
total request work also includes work hidden during the hold. Additional 0.25/1/3-second
figures are arithmetic projections from observed durations, not additional paced trials.
The default report is ignored `bench/results/prefill.json`; use `--repetitions 1` and a
different `--output` for a smoke check. CHECKS.md records the results and integration decision.

The accepted app change calls `HTTPCleanup.preparePrefix()` during configuration after
cleanup health/model validation and before capture/hotkey readiness. This covers launch,
saved settings, wake/session recovery and explicit **Check readiness**. It does not add
a per-recording request or idle timer. The existing preparation epoch/cancellation gates
still guard readiness. Preparation is bounded by the configured cleanup timeout; an
incompatible response or failure leaves the app in its existing recoverable setup-error
state. Final cleanup retains the final transcript, context cap and dictionary corrections.
Both preparation and final token counting now include BOS to match the chat endpoint.

`whispr-bench --cleanup-prefill-check` compares three synthetic outputs before/after
the actual Swift prefix-preparation method using the saved service configuration. It
prints only the pass count, measures no timing and does not change settings. Physical
first-dictation and independent service-restart recovery still need separate acceptance.

For the signed native synthetic batch check, launch through Launch Services so macOS
attributes Accessibility to the app. Direct tool execution can attribute permissions to
the invoking process instead. It runs one warmup plus 30 interleaved rounds per fixture,
verifies exact repeat output/native NSTextView contents, requests a native draw and
records monotonic ASR/cleanup/insertion spans without prompt, dictionary or result text.
Keep the Mac unlocked and the controlled benchmark window focused; a changed/locked
destination is rejected by the same target-validation path as normal dictation.

```sh
open -W -n --stdout /tmp/whispr-batch.log --stderr /tmp/whispr-batch.stderr \
  'dist/Whispr Lite.app' --args --batch-flow-check \
  "$HOME/Library/Application Support/WhisprLite/Models" \
  "$PWD/bench/results/audio" "$PWD/private/openwhispr" \
  http://127.0.0.1:11436 "$PWD/bench/results/batch-flow.json"
open -W -n --stdout /tmp/whispr-readiness.log --stderr /tmp/whispr-readiness.stderr \
  'dist/Whispr Lite.app' --args --readiness-report "$PWD/bench/results/readiness.json"
```

The readiness probe performs normal configured preparation and a bounded startup check,
records content-free permission/pipeline/event-tap status and exits. Normal operation has
no readiness polling. The batch check uses synthetic PCM, excludes microphone capture,
physical release, display compositor delay and third-party fields, and therefore cannot
close release-to-visible-text acceptance. Do not run integration benchmarks alongside
builds or other model loads when assessing latency.

For an opt-in acoustic benchmark on this Mac, `--capture-flow-check WAV SOX DEVICE
EXPECTED_WORDS OUTPUT_JSON REPETITIONS` opens the app's measured native text field, waits for normal
readiness, starts real microphone capture, plays the synthetic WAV through the named
CoreAudio output with SoX, releases after playback, and requires a visible native text
update. Run one pilot before 31 repetitions (one first-use and 30 warm). The app writes only stage timings, a
synthetic-phrase detection boolean and capture-start failure count to the ignored JSON;
it does not save captured audio or text. For example:

```sh
open -W -n --stdout /tmp/whispr-capture.log --stderr /tmp/whispr-capture.stderr \
  'dist/Whispr Lite.app' --args --capture-flow-check \
  "$PWD/bench/results/audio/short.wav" /opt/homebrew/bin/sox \
  'MacBook Pro Speakers' 'hello world' "$PWD/bench/results/capture-flow.json" 1
```

The saved ASR/cleanup settings and microphone are used; the system default output is
unchanged. Press/release are invoked inside the benchmark, so event-tap response and
physical key action remain separate acceptance gates. The visible timestamp comes from
the native text view's change callback, not the display compositor or another app. A
silent or echo-cancelled input yields no timing report; do not treat it as a latency
sample. Quit other Whispr Lite instances before running this finite mode and reopen
the normal signed app afterward.
