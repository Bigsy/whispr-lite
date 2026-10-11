# Development and validation

The native app consumes the published ParakeetCore 0.2.0 Swift package. It is not a validated
replacement for OpenWhispr yet. A configured local stack and private import from installed
OpenWhispr 1.8.3 are available on the development machine. Synthetic native integration
passes; physical capture, other destinations, playback and daily-use acceptance remain open.
Python cleanup harnesses load saved settings through `cleanup_bench.load_saved_cleanup`:
missing prompt/dictionary files use the app defaults, saved prompt whitespace is kept,
and symlink or oversized private files are rejected without printing their contents.
The optional OpenWhispr archive exporter opens the ASAR header and individual entries
only for each read, closing the file before it writes any private export.
The synthetic speech generator has an explicit entry point and one 16 kHz mono PCM
format definition; importing it for inspection does not generate audio.
The synthetic setup suite checks the benchmark stack lock against the pinned cleanup
runtime, model artifacts and actual server arguments. The media probe reads its adapter
revision from the benchmark lock.
`scripts/swift-env.sh` supplies the shared SwiftPM module-cache and build flags to
the app and candidate scripts; the Makefile uses equivalent variables. The arm64 app
build uses its known SwiftPM output path after one build, then signs the complete bundle.
The app build resolves the compiler path once for its resource-bundle adapter, which
still resolves it itself when run outside the app build.
Both GitHub workflows select the pinned Xcode through `.github/actions/setup-swift`.
CI runs for Markdown changes too, including notices and install guidance shipped in
the signed app or release archive.

Cleanup prepares its fixed system prompt once per configuration. Chat, template and
tokenizer requests share bounded message construction and JSON POST framing, while
the prepared prefix retains its exact server token budget and BOS handling.
Cleanup readiness checks health and the configured model using that cleanup instance's
endpoint and HTTP client; app startup retains the roughly 15-second retry sequence.
The coordinator owns an immutable batch pipeline and keeps its insertion-session marker
private. Demo ASR test knobs and the fake streaming session are internal; the public
demo backend remains available to the app. Timing stages contain only emitted stages.
ASR preparation progress stores stable enum codes in diagnostics and exposes separate
display labels for the Settings status line.
LatencyRecorder supplies session-scoped millisecond spans for app and synthetic native
reports. Its event buffer trims from 1281 to 1024 records in batches, avoiding a
per-event array shift after saturation.

## Build and run

Requires Apple Silicon, macOS 14+ and Swift 6.2. `make build` assembles
`dist/Whispr Lite.app`; open it with `open 'dist/Whispr Lite.app'`. Build/test do not install,
restart or reconfigure model services or login items. The app's SwiftPM dependency is
ParakeetCore, pinned to exact 0.2.0 with `Package.resolved` retained.
New settings default to direct local Unified ASR, with real Gemma
cleanup. Demo output is a development mode with no Settings switch: to test fabricated
output without services, quit the app and set `"backend": "demo"` (optionally
`"streamingDemo": true`) in `preferences.json`. Demo bypasses real ASR and cleanup and remains
visibly marked; choosing a speech recognizer on the General page leaves it.
Saved HTTP settings remain HTTP. For local ASR, select a complete model cache in Settings,
or enable **Download missing ASR models when preparing** before saving. Downloads are off
by default. A blank cache path uses `~/Library/Application Support/FluidAudio/Models`.
Preparation shows cache/load/warm-up/download stages and explicit library errors.

Settings are split into **General**, **Cleanup** and **Advanced**. General holds recording,
microphone, media and permission controls; Cleanup holds the private prompt/dictionary and
dictation history; Advanced holds relevant model paths/downloads, local service URLs,
capture/deadlines and diagnostics. Rows are grouped with the label
and a short caption on the left and the control on the right; longer detail is in tooltips.
The window is 640 points wide and not user-resizable: its height follows the selected page
with the top edge fixed, so ordinary settings fit without scrolling (613 to 738 points in
the synthetic renders). A page taller than the screen is capped and scrolls, with Save still
visible. The prompt and dictionary editors scroll inside; drag the grip under each to
resize it, and the window follows. Editor heights are remembered. Help/errors wrap.
Saving unrelated settings preserves custom hotkey configurations.

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
The POSIX locale used for alias keys is shared instead of allocated for each match.
`whispr-bench --dictionary-check` runs five synthetic inputs through the actual saved
cleanup configuration (requires the private Doccla conversion); the HAPI FHIR rule is
added in RAM for that check. It records only the pass count, never private text or outputs.
Each input carries its own acceptance predicate, so changing fixture order does not
change which correction the check expects.

A compact native floating pill shows Listening, Processing, Inserting or a recoverable
error with Copy when text is available. It uses a nonactivating panel, hides when idle,
and never displays transcript text. Its status updates on lifecycle changes; the optional
audio-level wave runs only while recording, with no idle timer, polling or capture-thread
UI work. Full-screen/Spaces/multi-display
focus and accessibility acceptance still need the manual matrix.

Open the settings directly with `open 'dist/Whispr Lite.app' --args --settings`.
Closing Settings discards its view state; reopening builds a new view from saved
preferences/private text and enumerates available microphones again.
Saving settings reports the invalid field for deadlines, local URLs, model folder and
private text limits. File-system failures get a separate save error.
Clipboard restoration keeps a named pending snapshot and uses one delayed-settlement
path for the fallback timer and the paste-read grace period, preserving owner checks.
Media broker shutdown sends end/shutdown before a shared transport reset; failures use
the same reset, which invalidates the process epoch before clearing queued state.
Notification observers registered on the main queue handle app suspension, shortcut
recorder focus loss and audio engine configuration changes on the main actor directly.
Core key-code constants are shared by hotkey handling, shortcut recording, presets and
the UI preview. Shortcut display tables are initialized once.
The shortcut recorder derives its active key from the pending candidate, and the
physical modifier definitions live with the hotkey state machine.
The event-tap hotkey state machine dispatches key, legacy modifier chord and Fn
gestures through separate bounded branches. Release and interruption share reset
helpers; interrupted gestures wait for a full release before another press.
PCM16k owns the 16 kHz rate, 640-sample streaming chunk and 120-second maximum;
SettingsStore and Preferences own private text sizes, settings version and deadline
range. History and diagnostics expose their default storage totals for Settings
captions. The recording ceiling captures its duration at press. The signed bundle ID
remains an explicit smoke-check expectation, while insertion identifies the app by PID.
`WhisprLite --ui-preview OUTPUT_DIRECTORY` renders synthetic native settings at each page's
fitted height and on a 560-point short screen, in light/dark appearances, plus indicator
states. `settings-heights.json` records each fitted height; a real titled window must fit
its content to the page with the top edge fixed, or the command fails. It starts no hotkey,
audio, model or service, and reads/writes no real settings. Preview images are not a focus or
visible-insertion acceptance test.
The preview shares offscreen host setup between snapshots and the active-only activity
draw check; its reported observations per condition derive from run and warm-up counts.
Synthetic and aggregate check reports use one atomic JSON writer with sorted keys;
the callers still define each report's fields and privacy boundary.
Demo mode keeps the `DEMO` marker on its status, menu, settings choice and recording
indicator; it never substitutes fabricated text for a failed real backend.

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
Archive hashes stream from disk. Packaging failures name the validation error or failed
tool, exit status and the last eight stderr lines, without printing command arguments.

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
capture once its notifications have been quiet for 500 ms; more than three rebuilds in
30 s asks for a readiness check. A press
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
clearly. No clipboard content or media titles are logged/persisted; dictated text is
persisted only by the local dictation history below.
The last result is bounded to 32,768 characters in RAM and cleared on the next recording.

**Keep dictation history on this Mac** (Cleanup page) is on by default, including for saved
preferences without the key, to collect local training data for the cleanup model. Each
completed batch dictation appends one JSON line to `History/dictations.jsonl`: schema,
timestamp, raw transcript, final cleaned text (after phrase conversions), the speech model
and a 16-hex SHA-256 prefix of the cleanup prompt, so pairs from different prompts can be
separated. The prompt, audio, target app and timings are not stored. Demo output, cancelled
dictations, empty results, cleanup failures and `--capture-flow-check` runs are skipped.
The coordinator only enqueues before insertion; encoding and writes run on a utility queue
with at most 64 pending entries. The folder is 0700 and excluded from backups; the file is
0600 and rotates at 16 MiB into `dictations.previous.jsonl`, so at most 32 MiB is kept.
**Delete history…** removes both files after confirmation, and saving continues while
enabled. A file error stops saving and shows a warning; saving settings or a readiness
check retries. Nothing is uploaded. Checks and benchmarks keep using synthetic fixtures.

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
`5266f24da75dc449bd56cbed7addb9c8e4a6a73e`, with SHA-256 checks for every file in
the owned standalone release, including the binary and its non-system libraries;
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
and atomically installs verified files. Model and release archives share this path;
a complete partial is hashed once before publication. Defaults are under
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
off-main-thread writes and reads keep ASR independent. Chrome reports our pause and a new
opaque item ID in the same update, often without comparable track metadata; until the
pause is confirmed, the same player process with no contradicting metadata is treated as
that refresh. Once confirmed, any item change still cancels the resume. Duration may
differ by up to 1 s. Real player/footprint/power acceptance remains open in CHECKS.md.

## SwiftPM and real-model integration

Normal builds resolve `https://github.com/Bigsy/parakeet-ane-server.git` at exact `0.2.0`,
whose published tag points to `09873950b95b966ad8237caca1be1d604d235db6`. A sibling checkout
is unnecessary. Keep `Package.resolved` with the app to freeze transitive dependencies.
Both batch and streaming APIs are linked, while normal dictation uses batch.

For direct Parakeet dictation, the audio worker publishes completed speculative PCM
chunks while the key is held. It waits for a 250 ms quiet stretch after at least 10 s
of audio and closes a chunk at 15 s at the latest. The worker copies owned audio on
its serial conversion queue; the real-time callback still only hands off packets.
Each chunk is transcribed and cleaned only if ASR ends it with sentence punctuation.
The normal full-audio batch transcription still runs after release and owns the raw
history text. Completed cleanup is reused only when all early chunk words exactly
match the start of that final transcript and cleaned chunks end as sentences. The
remaining final transcript is cleaned separately. An unsafe seam, failed early work
or missing chunk falls back to full cleanup. The insertion target and final-only
delivery are unchanged. Demo streaming and HTTP ASR do not use this path. A long
recording can therefore save cleanup time without changing ASR's final words; real
speech quality and release-to-visible-text speed still need physical validation.

The release path reads the audio host-time boundary before changing the processing UI
state and passes it to the capture worker. Early cleaned-prefix reuse keeps leading
symbols such as currency signs and quotation marks in the remaining tail. Hold warm-up
restarts after each early chunk while recording; the next chunk waits for it to settle
before using the engine. Invalid demo-streaming PCM closes its bounded sender with an
error. Copy-only completion uses the same session teardown as normal completion and
failure, preserving recovery text while clearing the target and early worker.

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
The build requires ParakeetCore and FluidAudio licence files and the smoke check verifies
they are present and nonempty in the signed bundle. The app media framework compiles only
the upstream files needed by the broker; `scripts/build-media-upstream.sh` creates a
separate full framework for the one-shot media benchmark. The broker restores default
SIGTERM handling, and its real-framework process test checks that termination exits.
The broker keeps bounded track identity in helper-local named fields, strips it from
wire replies, and compares a single track match when deciding whether a refreshed
opaque media item still belongs to the owned player.
The native broker tests and optional media probe use the same Python `BrokerClient`
for line decoding, generation/request IDs, deadline errors and process teardown.
The probe waits for a `resumed` event with its lease's original begin request ID.
Explicit `make install` stages and verifies the signed app before replacing the old copy.
An optional model argument selects another cached stack, for example
`WhisprLite --asr-check /absolute/path/to/Models ultra`.

The release bench executable accepts `--parakeet-check CACHE WAV_DIRECTORY OUTPUT_JSON`:
validated 16 kHz mono synthetic WAVs, 30 warm repetitions each, empty/silence, cancellation,
reuse and unload/reprepare. `--streaming-check` uses the same arguments and checks ordered
640-sample input, partial revisions, final text versus batch, cancellation/settlement,
batch fallback and returning to streaming. It sends audio without capture pacing and
does not measure physical partial lag, visible insertion, cleanup or ground-truth WER.
The Parakeet streaming adapter lives only in the bench target; the signed app uses
the batch adapter. Published builds include streaming bench modes. Local candidate
builds enable them with `PARAKEET_STREAMING=1` when that candidate supports sessions.

`--streaming-prototype CACHE WAV_DIRECTORY OUTPUT_JSON --repetitions 30` compares
the pinned Unified adapter with batch on the same synthetic files. It feeds 640-sample
chunks on a 40 ms capture schedule, holds the end until the audio duration, and records
first partial, append lag, finish call, residual after release and batch inference time.
Batch samples bracket the streaming block; model-mode switches and session creation are
outside the timed capture spans. It also measures a cancelled-stream-to-batch fallback
and reset. The raw JSON is ignored under `bench/results/`. Use normal GPU access, close
the running app during measurement, and do not supply private recordings. This bench
does not include microphone buffering, Gemma cleanup or visible insertion.
With `--record-partials`, the prototype also records synthetic partial text for a
follow-up prompt-cache mock; the 30-run report retains only partial counts and timing.
`python3 -B scripts/bench-cleanup-models.py --binary /absolute/path/to/llama-server
--candidate LABEL /absolute/path/to/model.gguf MODEL_ALIAS` compares the installed
Gemma service with one or more smaller local cleanup models. Repeat `--candidate` for
each GGUF; `--candidate-prompt LABEL PATH` optionally tests a different prompt for one
candidate. The script reads completed raw/cleaned pairs from the local OpenWhispr SQLite
database immutably and the saved Whispr Lite prompt/dictionary into RAM. The existing
11436 service is read only; each candidate runs alone on 11437 with logging and slot
persistence disabled, then stops. Synthetic checks use `bench/prompt-fixtures.json`,
`bench/model-cleanup-fixtures.json`, the bundled default prompt and a public dictionary.
Only aggregate scores/timings and public synthetic case IDs go to ignored
`bench/results/cleanup-models.json`. Real transcripts and generated text are never
written to the report. Use normal Metal session access, verified GGUFs in an ignored
directory, and the pinned llama-server. Historical cleaned text and Gemma outputs are
comparison references, not reviewed ground truth; this is cleanup-only, not an ASR or
release-to-visible-text measurement.

### Retired experiment harnesses

These rejected or unintegrated experiments remain in git history. Their measured
results and limits remain in CHECKS.md:

- Partial prefill: `git show ae1e6a0:scripts/bench-partial-prefill.py`
- Cleanup round trips: `git show ae1e6a0:scripts/bench-cleanup-roundtrips.py`
- Speculative cleanup: `git show bfef7f6:scripts/bench-speculative-cleanup.py`
- MTP plus n-gram: `git show 4b97c28:scripts/bench-ngram-cleanup.py`
- Apple Foundation cleanup: `git show 1c58515:scripts/bench-apple-cleanup.py` and
  `git show 1c58515:scripts/bench-apple-cleanup.swift`
- Unused compact prompt: `git show 1c58515:bench/compact-cleanup-prompt.txt`

The one-shot press warm-up prototype was retired after hold-time keep-warm shipped.
Its historical measurements remain in CHECKS.md under commit `58b318f`.

`--vad-trim-prototype ASR_CACHE VAD_CACHE WAV_DIRECTORY OUTPUT_JSON --repetitions 30`
asks whether Silero VAD silence trimming pays for itself before final batch ASR. It loads
the pinned FluidAudio Silero bundle (CPU only) from `VAD_CACHE/silero-vad-coreml`, and
downloads it there only with `--allow-model-downloads`; keep that cache in an ignored
directory, separate from the app's models. `--vad-threshold` defaults to 0.5. For each
synthetic WAV, plus the under-five-second clips joined by 2 s pauses and a noise-only
clip over a quiet synthetic noise floor, it times a full VAD pass and per-256 ms chunk
cost, then runs interleaved batch ASR on the original, edge-trimmed and pause-trimmed
audio (pauses of at least 0.75 s, 0.25 s padding). Unified pads every recording to a
fixed 15 s encoder window, so trimming saves only decoder frames unless it removes a
whole window; the report records each variant's window count, text/word parity and
the paired ASR saving. Release savings with VAD at release or run incrementally during
the hold are projections from separately measured spans. Close the app while measuring.

Batch ASR has nothing to do while the key is held, and the Neural Engine and CPU clock
down between 0.5 and 1 s of idle. Normal direct Parakeet dictation therefore runs one
1-second silence inference at press and again 500 ms after each one finishes, only while
recording (`holdWarmupInterval`). Nothing runs between dictations. Each pass is its own
task, so release or cancellation stops the loop without cancelling CoreML mid-inference:
release waits for a pass in flight before final ASR, and settings preparation waits
before unloading the old model. Other ASR backends and demo mode do not warm. Synthetic
measurements are in CHECKS.md; physical power use remains open.

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
committed ParakeetCore revision in `Package.resolved` from the sibling checkout by default
and restores that lockfile after the isolated candidate build. `PARAKEET_CORE_PATH` and
`PARAKEET_CORE_REF` override source/ref; `PARAKEET_MODEL_CACHE` selects a cached model root.
Local streaming candidates additionally use `PARAKEET_STREAMING=1`. This check
requires cached models and never substitutes fake output or downloads weights. Run a
normal `make check` afterwards to restore the published release's lockfile.

The streaming adapter waits for settlement before switching to batch fallback over the
capture's authoritative final audio. It holds no second full recording and reuses the
configured batch ASR/cleanup deadlines. If the delivered chunk count differs from the
final capture, it cancels the streaming session and uses batch. The app exposes streaming
only in demo mode pending the broader M7/M8 acceptance;
the real-model bench exercises the adapter directly. Streaming-partial prefill is not
enabled. Fixed cleanup-prefix warming now runs during app preparation (see below).

Settings distinguishes a missing private prompt or dictionary from an unreadable one.
Save preserves an unreadable file unless its editor was changed or the prompt was
explicitly reset. Local HTTP transport failures are mapped by their caller: cleanup
errors offer raw text, ASR errors report transcription failure, and health/model
readiness reports an unavailable service. Actual token-budget failures retain the
context-limit message. Local cleanup benchmark requests use a proxy-free opener so
private prompts and transcripts remain on the Mac even with proxy settings.
The private file helper creates/tightens 0700 directories and 0600 files, rejects
symlinks, and writes settings through 0600 temporary files renamed in the same directory.
Prompt and dictionary file reads use a typed private-file name; convenience accessors
apply the default prompt or empty dictionary only when the corresponding file is absent.
The app, native synthetic flow and bench build cleanup configuration through one
preferences initializer, including endpoint, import framing and dictionary prefix.
History and diagnostics share a serial-queue JSONL writer with one encoder per owner,
private open/rotate behavior and separate oversized-entry policies. Their caller-side
queues remain bounded at 64 and 128 entries, and their different retry rules remain.

## Checks and benchmarks

- `make test`: Swift boundary/lifecycle/audio/network/clipboard/streaming tests and native
  broker process tests, plus synthetic setup/migration/download/port/rollback tests; no
  microphone permission, model downloads, real login-item writes or private input needed.
- `make build`: arm64 release app, media framework, SwiftPM resource bundles, signature verification.
- `make doctor` / `make status`: read-only toolchain, plist, signature, port and service health checks.
  Missing services are reported and do not fail the fake development check.
- `make check`: tests, build, doctor and bundle smoke check.
- The fake orchestration benchmark was retired in the D15 tidy-up. Use the real
  synthetic batch and streaming checks above for ASR behavior.
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
Measurements include the app's proportional output limit, exact template/token-budget
requests with BOS, and completion, plus server prefill/generation metrics. This harness
does not prepare a fixed prefix, so it measures the app's exact-token path on each request.
`--import-file` preserves an imported dictionary prefix;
`--candidate-context-file` adds a private context line to a third comparison. `--quality-only`
skips performance. Reports contain metrics and synthetic case IDs, with no prompts,
dictionary contents or generated text. They exclude physical dictation, model-load cold
starts and long-idle/memory-pressure behavior. No app settings or services are changed.

Raw benchmark output lives in ignored `bench/results/`. Python benchmark reports share
the experiment, UTC timestamp, Git commit/dirty state, cleanup stack revision,
nearest-rank percentile method and one false `private_content_recorded` flag. The
writer checks supplied private strings before publishing a report. Earlier report
formats and percentile values remain historical and are not rewritten.
Swift reports use the same nearest-rank p90/p95 helper and a conventional median that
averages the two middle values for even counts. `JSONReport` names the method in its
object reports; old raw observations can be recomputed if a comparison needs it.
Retained benchmark entry points use `run_guarded()` to print only known safe failure
reasons or the exception type; request, response and private prompt text is suppressed.
[CHECKS.md](CHECKS.md) records the checked revision/environment and remaining
acceptance gates. Use the app's **Benchmark
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
`scripts/cleanup_bench.py` owns the proxy-free loopback client and isolated server
lifecycle for this and the candidate cleanup-model screen. It verifies the pinned
runtime once per run, frees the isolated port, checks health and model alias, and
terminates the process on exit. The candidate screen accepts only that verified
server binary; model paths may differ for a candidate comparison.
The same module projects dictionary vocabulary and applies literal whole-phrase
corrections for the candidate screen. Swift and Python check the shared synthetic
`bench/dictionary-cases.json` vectors, including overlapping aliases and boundaries.
Word parity uses Core's `WordTokens` in the app and Swift benches, with matching Python
scoring and shared `bench/word-cases.json` vectors. Both apostrophe styles are treated
as the same contraction; the benchmark scripts share synthetic fixture loading.
The fixed-prefix harness imports its summary helper directly from `cleanup_bench.py`;
it no longer loads the entire prompt-comparison program during startup.
Local benchmark endpoints and the model alias come from the pinned cleanup lock;
`loopback_url()` validates their base URL before any request or explicit configuration.

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
