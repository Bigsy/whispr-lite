# Implementation checks: 11 October 2026

The configured local batch stack and signed synthetic native insertion work on this
machine. These checks do not establish physical release-to-visible-text latency,
third-party insertion, actual media playback compatibility or release acceptance.

| Check | Result |
|---|---|
| 11 October report helper, Apple M1 Max | `make test` passed with 103 Swift, 17 native broker, 14 setup and 5 release tests. The debug app's `--ui-preview` wrote native renders and JSON reports to ignored `bench/results/tidy-json-report-ui`; parsed report keys matched the prior preview and the activity report retained 60 observations. No private content was used. |
| 11 October Settings reopen, Apple M1 Max | `make check` passed with 103 Swift, 17 native broker, 14 setup and 5 release tests, signed app, doctor and bundle smoke. Native `--ui-preview` passed fitted and 560-point renders in `bench/results/tidy-reopen-ui`. The code now rebuilds the Settings root view after close, so its `@State` starts from the current store and microphone enumeration runs on appearance. Reopen behavior with physical devices has not been manually exercised. |
| 11 October UI labels, Apple M1 Max | `make check` passed with 103 Swift, 17 native broker, 14 setup and 5 release tests, signed arm64 app, doctor and bundle smoke. Native `--ui-preview` passed at fitted and 560-point short-screen sizes (`bench/results/tidy-demo-ui`); the General renders were visually inspected with no clipped model or backend labels and Save visible on the short screen. Demo remains explicitly marked. Focus, physical capture and visible insertion were not exercised. |
| 11 October HTTP WAV encoder, Apple M1 Max | `make test` passed with 103 Swift, 17 native broker, 14 setup and 5 release tests, including WAV container/multipart length checks. A separate optimized synthetic microbenchmark compared the former per-sample writer with the bulk PCM writer in alternating order, 30 measured rounds per condition, with byte-identical output. Five seconds of PCM: median 1.549 ms versus 0.174 ms; 30 seconds: 9.212 ms versus 1.031 ms. This measures WAV serialization only; no HTTP, ASR, cleanup or release-to-visible-text improvement is claimed. |
| 11 October streaming bench move, Apple M1 Max | `make check` passed with 103 Swift, 17 native broker, 14 setup and 5 release tests, then signed app, doctor and bundle smoke. Cached Unified batch passed 3 synthetic fixtures and 90 warm observations with cancellation/unload. Streaming passed the same 3 fixtures with cancellation/fallback/reset. One paced repetition per fixture passed with explicit `--record-partials`: 1, 6 and 0 snapshots respectively, matching each fixture's partial revision count. Reports: ignored `bench/results/tidy-batch-d9.json`, `tidy-streaming-d9.json` and `tidy-prototype-d9.json`. The installed app was closed for model ownership and reopened afterward. These checks do not measure physical capture or visible insertion. |
| 11 October build pin cleanup, Apple M1 Max | `make test` passed with 103 Swift, 17 native broker, 14 setup and 5 release tests. Both media framework scripts compiled and signed with the deployment target read from Info.plist. `PARAKEET_MODEL_CACHE="$PWD/.build/models" make candidate-check` passed against the pinned `09873950` revision with downloads off; the candidate prepared and transcribed one second of synthetic silence. Its isolated build changed `Package.resolved` temporarily, and the script restored the published lockfile before exit. The installed app was closed for model ownership and reopened afterward. |
| 11 October warm-up buffer check, Apple M1 Max | After A19, `make test` passed with 102 Swift, 17 native broker, 14 setup and 5 release tests. The current release bench passed cached Unified batch on 3 synthetic fixtures and 90 warm observations, with cancellation/unload, and streaming on the same 3 fixtures with cancellation/fallback/reset. Reports: ignored `bench/results/tidy-batch-a19.json` and `tidy-streaming-a19.json`. The installed app was closed for model ownership and reopened afterward; the cleanup service was untouched. This validates ASR behavior, not a measured warm-up allocation saving or release-to-visible-text latency. |
| 11 October capture hand-off, Apple M1 Max | `make check` passed with 102 Swift tests in 26 suites, 17 native broker tests, 14 setup tests and 5 release tests, then signed arm64 app, doctor and licence/resource smoke check. With the installed app closed and downloads off, cached Unified batch ASR passed 8 synthetic fixtures and 240 warm observations plus cancellation/unload; streaming passed 8 fixtures with cancellation, fallback and reset. Reports: ignored `bench/results/tidy-batch.json` and `tidy-streaming.json`. The previously running installed app was reopened afterwards. These are ASR-only checks; physical release boundary timing, microphone capture, visible insertion and player behavior remain unmeasured. |
| 11 October tidy-up, Apple M1 Max | `make test` passed after the HTTP error mapping: 95 Swift tests in 26 suites, 17 native broker tests, 14 setup tests and 5 release tests with normal session access. A sandbox-only pasteboard failure reproduced before the normal-session rerun; no check was skipped. Synthetic HTTP regressions now distinguish cleanup 500 (`cleanup`), ASR 500 (`inference`), readiness 503 (`notReady`) and oversized transport bodies (`HTTPFailure.tooLarge`). Actual token-budget exhaustion still reports `contextLimit`. Earlier `make check` passed the signed arm64 app and licence/resource smoke check. Native Settings previews covered fitted pages, short-screen pages and an unreadable prompt warning. Physical dictation and player gates remain open. |
| `make check` | 68 Swift tests in 22 suites, 14 native broker process tests, 14 synthetic setup tests and 4 release-tooling tests passed on both GitHub workflows; arm64 release build, deep/strict signing, doctor and bundle/resource smoke checks. Local full checks also pass. Initial sandbox execution correctly failed native pasteboard/event creation; the local full check passed with normal session/keychain access, without skipped checks. |
| Dictionary / phrase conversion | Verified Doccla is present in the private dictionary and sent to Gemma; three synthetic “dochler” inputs still remained misspelled. A stronger instruction did not resolve them. Added explicit `spoken phrase > Written phrase` (`=>` also supported), compiled during preparation and applied once after successful cleanup. Unit/HTTP regressions cover whole-word and Unicode boundaries, case, literal regex characters, overlapping phrases, non-cascading rules, ambiguous aliases, empty/plain dictionaries and actual adapter output. Added the Doccla rule privately, preserving existing words/prompt with an ignored 0600 backup. Actual saved Gemma/MTP configuration passes all five synthetic cases, including happy fire → hapi fhir and unchanged doctor; command records only pass count. No physical speech accuracy claim. |
| Release packaging | Local preview ZIP packages and re-extracts the signed arm64 app; deep/strict signature and bundle/resource smoke pass from the extracted bundle. Both artifact hashes match the manifest; the cleanup kit contains exactly three allowlisted files. No private settings/dictionary/audio or GGUF weights in archives. Four synthetic tooling checks cover versions, injection, channel/tag policy and refusal to submit a development signature for notarization. Verified actionlint v1.7.12 passes both workflows. GitHub [Checks](https://github.com/Bigsy/whispr-lite/actions/runs/38062388216) and [Release](https://github.com/Bigsy/whispr-lite/actions/runs/38062433571) pass from clean commit `f24770b` on the pinned Apple Silicon runner/toolchain. The draft `v0.1.0-beta.1` has all four assets; downloaded hashes, clean-source manifest and commit match. Tagged releases stay drafts; stable tags require Developer ID/hardened runtime/notarization. Distribution credentials/notarization and another-Mac installation remain unverified. |
| Phrase-converter readiness/UI | Eighteen final synthetic native renders pass at compact/full sizes and light/dark appearances (`bench/results/phrase-converter-ui-final`); text wraps and the footer remains visible while long content scrolls. Final Launch Services probe reports saved Ultra, all three permissions, event tap and pipeline ready (`bench/results/readiness-phrase-converter.json`); no physical hotkey/dictation test. The normal updated app is reopened; saved model, shortcut, debug settings, custom prompt and cleanup service are retained. |
| Source publication | Audited the staged tree: private exports/settings, models, audio, builds and raw benchmark reports excluded. Anchored the private-export ignore rule to the repository root so required vendored MediaRemote sources are included. A separate staged snapshot built the native framework and passed all 14 broker and 14 setup tests; current source matches the full checked build. Sample settings now use direct Unified ASR and cleanup port 11436. Local documentation links resolve. Fresh-machine app/model installation remains a separate open gate. |
| Published ParakeetCore | Exact 0.2.0, revision `09873950b95b966ad8237caca1be1d604d235db6`; retained `Package.resolved`, FluidAudio 0.17.7, bundled resources/licenses. No sibling checkout needed for builds. |
| Real batch adapter | Six synthetic fixtures, 180 warm runs; empty/silence, actual duration, repeated output, cancellation/reuse and unload/reprepare passed. No fabricated fallback. |
| Real streaming adapter | Ordered 640-sample chunks, revisions/final, cancellation/settlement, batch fallback and reset passed. Five of six have equal normalized words to batch; long fixture differs. App remains batch; real streaming is bench-only. |
| Signed synthetic native flow | Real PCM → Parakeet → Gemma → native NSTextView update and requested draw; six fixtures, 180 warm observations plus six warmups, exact repeat output, empty/silence passed. No third-party/compositor/capture timing claim. |
| Normal signed readiness | Passed through Launch Services: Microphone, Accessibility and Input Monitoring authorized; actual event tap, configured offline ASR, exact cleanup alias and warm capture ready. Latest paste-fix probe: `bench/results/readiness-modifier-fix.json`. Reopened the signed app with Right Control/debug enabled; its normal run logs ready without failures and retains directory 0700/file 0600. No identifiable subscribed player in the finite probe; control safely skipped. Physical hotkeys were not exercised by the probe. |
| Right Control startup recovery | A later probe found missing owned/default ASR caches and an absent cleanup service; push-to-talk was inactive. Restored verified local assets to owned app caches, backed up preferences and selected the owned ASR folder while retaining key code 62 and private text. Restored the owned cleanup LaunchAgent on 11436. Signed Launch Services probe now reports ready pipeline/event tap and all three permissions; physical key/popup acceptance remains pending. |
| Support folder recovery | A subsequent check found the owned models, diagnostic logs/backups and cleanup LaunchAgent absent, with default private text/cache/debug preferences. Cause remains unproven; reviewed install/restart/build paths preserve support assets, and the latest full build retained the restored model/settings files. Reverified source and cloned ASR/Gemma/MTP SHA-256, backed up defaults, restored the exported private cleanup profile, retained Right Control and enabled debug logging. Final signed Launch Services probe reports ready ASR/cleanup/event tap and all three permissions; the normal reopened app logs ready with directory 0700/file 0600. The probe safely skipped media control because subscription health was unavailable; subsequent dictation/Spotify observations are recorded in the retest rows below. |
| Signed cache failures | Separate APFS cache clones with a partial marker or corrupt compiled encoder fail clearly with downloads off. Live/default/shared caches are untouched. `bench/results/asr-cache-errors.json` records the content-free diagnostics. |
| Private import | Installed OpenWhispr 1.8.3 prompt resolution, English/language instructions, 188 dictionary entries, dictionary suffix and transcript framing recovered. Read-only source; no history/credentials queried. Private files ignored and 0700/0600. |
| Cleanup request/context | Imported tags/suffix, trimmed output, temperature zero and reasoning off; exact server chat-template/tokenization with 512 generation tokens reserved. Automated overflow and wrong-alias rejection passed. |
| Real cleanup | 24 synthetic inputs, 720 interleaved warm observations plus 24 warmups. Repeat outputs equal; 24 additional comparisons match the reference's 4096-token output budget. Warm median 131.34 ms, p90 167.63 ms, p95 170.96 ms. No saved prompt/dictionary/result text. |
| Pinned assets/runtime | Full model/MTP SHA-256 and sizes, llama.cpp 0.4.0 revision/binary/linked-library hashes/required flags verified. Matching QAT MTP, draft length 6, `swa-full`, one 4096-token slot, flash on, `mmap+mlock`, reasoning off and 86400-second Metal residency. |
| Explicit service setup | Actual owned LaunchAgent install → uninstall → reinstall passed. 11436 healthy; models/preferences preserved. Ollama on 11434 and OpenWhispr remain untouched. Port conflict, foreign agent, checksum failure, startup rollback and asynchronous teardown covered synthetically. |
| Standalone cleanup release | Downloaded official macOS ARM64 b10809 at the same v0.4.0 revision, verified GitHub's archive SHA-256 and pinned all 60 runtime files. Mach-O dependency inspection found only included libraries/Apple system dependencies, all declaring macOS 13.3 minimum. Starts Gemma QAT + MTP with existing tuning; all 24 synthetic outputs match the previous service. Owned production LaunchAgent switched and healthy. Setup tests cover staged/reusable provisioning, corrupt download/runtime rejection, unsafe archive paths/links, preserved settings/models and clean child environment. New-release physical latency, other-machine setup and older-macOS compatibility remain unmeasured. |
| Media recovery | Real synthetic Perl processes cover one/repeated crashes, stale generations, permission/fatal, malformed/oversized output and slow readers while fake ASR still inserts. At most two replacements per run; no old lease replay; shutdown cancels recovery. |
| Native broker ledger | Fourteen process checks use production ordering/lease/pipe code with a compile-time fake provider. End-before-query/issued-pause, duplicate end, new sessions, unknown/paused/untrusted state, identity changes, external playback, unconfirmed pause, old generation, EOF, fragmented/oversized input and Objective-C numeric boolean normalization pass. Opaque-ID refresh with matching content, actual content/player changes, invalid/missing metadata and protocol privacy pass in normal/debug modes. |
| Shortcut recorder | Native Record sheet; physical Left/Right Control and other modifiers, regular/Fn chords, release confirmation, Escape/focus cancellation and saved-setting persistence. Six automated tests (including nine modifier cases) cover capture and runtime side/chord/ordinary-shortcut behavior. Physical-key acceptance remains in the hardware matrix. |
| Settings/indicator | General/Cleanup/Advanced, wrapped/scrollable content, fixed save footer, conditional ASR controls and custom shortcuts. Eighteen synthetic native renders include compact/full speech-model choices, light/dark Cleanup with the default-prompt button, Right Control settings, recorder sheet and speaking/silent compact pills. Content scrolls at minimum size while Save remains visible. Latest renders: `bench/results/model-picker-ui`. Normal indicator window is 238×64; errors retain 360×94. No transcript display or idle timer; the active meter timer stops on processing, cancellation, lock and hide. |
| Speech-model picker | Unified (default), Ultra, TDT v2 and TDT v3 feed the pinned library's actual batch model choices. Tests cover all four factory IDs, explicit missing-cache failure for each, old-settings migration, saved model/private-text/shortcut persistence, unknown-value rejection and debug model identity with old-record compatibility. Only local Parakeet displays the picker. Previous setup settles and the old engine must unload before the new model loads; a busy engine fails preparation clearly. No recording callback or pipeline timing added. |
| Audio feedback | Four tests cover noise/silence/decay, rate bound and unchanged captured PCM/reset. 30 interleaved synthetic 48 kHz stereo conversion runs per condition: enabled median 11.990 ms versus disabled 11.948 ms for two seconds of audio; paired median delta 0.016 ms. Isolated wave observation avoids refreshing labels/material. Synthetic hosting/bitmap draws: paired incremental median 0.563 ms/update at a 10 Hz limit. These are worker/CPU-draw checks, not physical capture, compositor/GPU, power or release-to-text measurements. |
| Debug logging | Off by default; typed JSONL with run/session IDs, monotonic timing stages, configuration flags, preparation/readiness, paste failure reasons, clipboard ownership outcome and media command/reply booleans. 128 pending records maximum; two 2 MiB files, 0700 directory/0600 files; off-thread writes drop on saturation and stop after disk failure. Four tests cover disabled-mode laziness/migration, privacy, rotation, saturation/failure and timestamp correlation. Clock-injection checks prove disabled timing takes no clock reads/callbacks/events; capture checks prove no first-audio diagnostic timestamp. Normal pipeline has no timing callback or diagnostic actor hop; explicit benchmarks enable timing. Native debug-off check verifies no extra invalidation event or reason field. |
| Diagnostics trial startup | Enabled logging in the user's existing preferences after a private backup, retaining Right Control (62) and all other settings. The final signed Launch Services probe ran at the login window: all three permissions granted, pipeline/event tap paused; the local log recorded logging enabled and suspension. Confirmed directory 0700/file 0600 and summary reader. Reopened the final app's settings; subsequent unlocked real-use evidence is recorded in the retest rows below. |
| Real media wire format | Read-only probe of the final bundled helper returns `known: true`, with boolean playing/trustworthy/subscription-health fields. Previously the actual provider returned numeric `known: 1`, which the app rejected. No playback command or media title was queried by this probe; Spotify pause/resume acceptance remains open. |
| Spotify debug evidence | The earlier retest confirmed pause, then `itemChanged` while paused and `noLease` at end without a user playback/track change. Updated the guard to accept an opaque-ID refresh only with matching bounded metadata and the same player/process; retain actual metadata/player/lifetime/external-playback invalidation and strict missing/invalid-metadata behavior. Synthetic regression verifies one resume in debug/on normal modes and no metadata in protocol replies. The latest six-session retest records four confirmed pauses, three confirmed resumes and one unconfirmed resume; the user reports Spotify working. The complete player/cycle matrix remains open. |
| Debug-only instrumentation startup | The earlier debug-only `make check` passed with 55 Swift/11 native broker/10 setup tests and no compiler warnings. Reopened that signed app unlocked with the existing debug preference enabled; its new run recorded prepared ASR, granted permissions, ready event tap and valid media snapshots. Summary reader's synthetic media spans/reason filtering pass. Real logs showed both ASR and cleanup completion; live owned server flags and verified artifacts matched Unsloth Gemma 4 E2B QAT plus MTP, draft length 6. The app explicitly selects Parakeet Unified 0.6B; CoreML config allows CPU/ANE for its int8 encoder and CPU decoding. These logs do not profile actual NPU execution or establish output accuracy. |
| Generic paste review | Inspected installed OpenWhispr 1.8.3 public clipboard/media helpers (MIT; file hashes recorded). macOS uses generic Command-V. Removed app-specific terminal exceptions and AX write-capability requirements from our Command-V validation; retain saved focus, enabled/secure/readonly checks, keyboard layout, clipboard ownership and one insertion attempt. Ghostty and other destinations still need real-use verification. |
| Missing insertion retest | All six observed sessions completed ASR and cleanup. One stopped before paste with `modifiersHeld`; five dispatched Command-V, which alone does not prove visible text. The old logs lack modifier categories, so stale synthetic/session state is a hypothesis. The gate now reads HID hardware state; Command-V uses a private event source and session injection, matching the posting level in OpenWhispr v1.10.2's current helper. Five regression tests cover the clear path without clock/sleep, bounded real-held-key waits, cancellation and tagged Command-V events. The 250 ms guard, target/layout/clipboard checks and single insertion remain; no arbitrary paste delay added. Debug-only typed hardware/session categories and wait summary pass privacy checks. Report: `bench/results/missing-paste-retest.json`; physical verification after the change remains pending. |

## Fixed-prefix prefill experiment and integration

10 October 2026: 360 observations, 30 per fixture/condition, rotating condition and
fixture order. The temporary Metal server used the checksum-verified pinned Gemma/MTP
stack and existing tuning on port 11437, with `--cache-ram 0` to prevent restoration of
previous complete transcripts. The installed 11436 service remained running. Three
synthetic inputs used the saved prompt, projected dictionary vocabulary and framing,
all held only in RAM. No model downloads, service installation or preference changes.

The mock holds a button for 500 ms, evaluates the fixed prefix at press when enabled,
then waits for any unfinished prefill before the normal template/token-budget/final-chat
requests. There is no physical capture, ASR or insertion. All model loading is outside
the spans; a forced prompt-cache miss is not a model-cold or long-idle measurement.

| Input / prefix state | Baseline release → cleanup median / p95 | Prefill release → cleanup median / p95 | Paired median saving |
|---|---:|---:|---:|
| Question / miss | 725.65 / 745.13 ms | 227.07 / 243.32 ms | 498.91 ms |
| Correction / miss | 720.59 / 732.58 ms | 224.85 / 240.61 ms | 495.43 ms |
| Long request / miss | 1207.44 / 1236.89 ms | 668.77 / 692.70 ms | 540.32 ms |
| Question / warm | 175.62 / 207.33 ms | 176.76 / 189.77 ms | -2.45 ms |
| Correction / warm | 171.08 / 182.89 ms | 172.83 / 181.92 ms | 0.26 ms |
| Long request / warm | 643.97 / 670.15 ms | 643.20 / 660.64 ms | 2.68 ms |

Exact trimmed model outputs matched across every condition/repetition (180/180 paired
comparisons); no additional post-cleanup dictionary substitution was needed for this
comparison. This is parity on three fixtures, not a broader accuracy claim. The 968-token
fixed prefix was reused in every final prefilled request. Median preparation cost was
597.55 ms on a forced miss and 12.57 ms when warm. Total request work was approximately
unchanged (and increased for the short fixtures); most of the benefit moves work before
release. Longer-lead figures in the raw report are projections, not measured trials.

Two initial probes were excluded. The first omitted BOS when converting the template
to explicit token IDs: this shared no prefix with chat completion. Automatic full-prompt
RAM-cache restoration initially masked the mistake by reusing a prior complete input.
The corrected harness includes BOS and rejects both missing-prefix and excessive cache
hits. The pinned server also samples/emits one token even at `n_predict: 0`; the harness
and app discard it. True zero-generated-token behaviour is not claimed. Sandbox Metal
startup failed before measurements; the successful run used permitted normal GPU access.

Decision: integrate warming once during app preparation, before recording readiness.
The negligible warm gain does not justify per-button-press prefill. The user's instruction
authorised integration if the experiment succeeded. The implementation also includes BOS
in final context-budget checks. Independent service-restart detection, idle/pressure,
physical first-dictation and release-to-visible-text acceptance remain open.

Report: ignored `bench/results/prefill.json` (metrics/parity only). The temporary server
stopped on exit and the installed service remained healthy. The report's 360 rows and
metric-only schema, Python syntax and `git diff --check` passed.

Integration `make check` passed: 69 Swift tests in 22 suites, 14 native broker tests,
14 setup tests and 4 release-tooling tests; arm64 release build, development signature,
doctor and bundle/resource smoke check. The focused HTTP regression checks BOS in the
tokenizer requests, native prefix framing, discarded single-token output and rejection
of unexpected generation. Its first run exposed the fixture's missing streamed-body
capture; that test helper was corrected and the complete check rerun successfully.
The actual Swift `--cleanup-prefill-check` passes all three synthetic exact-output
comparisons against the installed service, including saved dictionary corrections.

The signed Launch Services probe (`bench/results/readiness-prefill.json`) found a paused
session: all permissions granted, `ready=false`, pipeline/event tap disabled and status
“Dictation paused”. It therefore did not exercise unlocked preparation readiness or
physical dictation. That gate remains open; it is not a prefill failure or a ready claim.

The prior running app was gracefully quit and the newly signed `dist/Whispr Lite.app`
launched in the background. Its 10 October 2026 startup diagnostics record
`preparationReady` after 535.9 ms and `readiness=ready` with the media helper ready.
For the configured local backend, cleanup prefill is awaited before
`preparationReady`, so this verifies the normal startup path completed. No physical
push-to-talk, final insertion or release-to-visible-text timing was measured.

## Paced Unified streaming and partial-prefill prototypes

10 October 2026: the pinned published ParakeetCore Unified adapter received 640-sample
chunks on a 40 ms schedule. The app was closed to avoid model contention. Three synthetic
Samantha clips under five seconds each had 30 batch and 30 streaming observations; batch
samples bracketed each streaming block. Model preparation and mode switches were outside
timed capture spans. These are ASR-only estimates, with no microphone, Gemma, insertion,
CPU/ANE-energy or release-to-visible-text measurement. Streaming residual includes work
remaining after nominal audio end. Results: ignored `bench/results/streaming-prototype.json`.

| Synthetic clip | Audio | Batch median / p95 | Streaming residual median / p95 | First partial |
|---|---:|---:|---:|---:|
| Hello world | 0.96 s | 59 / 61 ms | 152 / 207 ms | none |
| Thursday, no Friday | 2.66 s | 66 / 67 ms | 105 / 124 ms | 2.23 s median |
| Sentence with pause | 4.19 s | 71 / 76 ms | 168 / 193 ms | 2.24 s median |

Streaming and batch words matched in all 90 runs. The one-second clip differed in
punctuation in every run; the other two had exact text parity. Median maximum append lag
was 3, 147 and 159 ms respectively; this bench does not reproduce the app's finite
capture-stream buffer. A cancelled-stream-to-batch fallback, including model-mode switch,
took 280 ms; returning to streaming took 169 ms. A single exploratory 25-second paced run
had 162 ms residual versus 252 ms batch, but the long fixture has an existing word-level
streaming/batch disagreement and does not represent the user's roughly 99% under-five-
second workload. The decision is to keep batch in normal dictation.

One additional paced pass recorded only synthetic partial snapshots. The one-second
clip produced none. The correction emitted “Thursday” at 2.21 s, 452 ms before release;
the pause clip emitted “Start the sentence” at 2.21 s, 1,985 ms before release. Its later
partial arrived after nominal release. With the already warm 968-token fixed Gemma prefix,
these first snapshots added only one and three reusable tokens to their final prompts.

The isolated pinned Gemma server then ran 30 baseline/partial-prefill pairs for each
eligible clip, disabling RAM restoration of prior full prompts. Exact trimmed cleanup
output matched across conditions. Baseline median final request was 92 ms for correction
and 137 ms for pause; partial prefill cost 45 and 48 ms before release, reducing median
final request to 90 and 132 ms. Paired projected median release savings, including any
prefill spill past the measured lead time, were only 2.0 and 1.5 ms. This mock did not
run Gemma concurrently with ASR or measure contention, and its projected release savings
are not app timings. Report: ignored `bench/results/partial-prefill.json` (harness `ae1e6a0`). The temporary
server stopped; the installed cleanup service remained healthy. No streaming or
per-recording Gemma prefill was integrated.

The next small mock compared the current `/apply-template` and `/tokenize` preflight
against a direct chat request on those same three synthetic short transcripts, 30 paired
observations per fixture in rotating order. It reset the isolated pinned server to the
same warm fixed prefix before each condition and verified exact cleanup output parity.
The checked path spent a median 4.4–4.7 ms on the two preflight requests. Paired median
end-to-end saving without them was only 2.2 ms for correction, 4.0 ms for pause and
3.2 ms for the one-second clip; final-request timing noise offset some preflight cost.
The direct-request mock skipped exact preflight context validation, so it was not
integrated. Metric-only report: ignored `bench/results/cleanup-roundtrips.json` (harness `ae1e6a0`). The
temporary server stopped and the installed service remained healthy.

The signed app was relaunched after the model runs; startup diagnostics recorded
`preparationReady` in 571 ms and `readiness=ready` at 17:09 UTC.

## Speculative full cleanup mock

10 October 2026: one paced Unified pass on each existing synthetic clip, plus one pass
each on the 0.96 s short and 2.66 s correction clips with 2.7 s and 1.8 s of appended
silence. The final clips were 3.66 s and 4.46 s. The app was closed for CoreML and
reopened afterward. The ordinary short clip emitted no partial. The first ordinary
correction and pause partials differed from their final transcripts. With appended
silence, the short clip emitted an exact final-matching partial 1,416 ms before release;
the correction clip's first two partials were wrong and its exact one arrived only
163 ms before release. These ASR snapshots have one observation each, so partial-match
frequency and accuracy are not established.

An isolated pinned Gemma server on port 11437, with full-prompt RAM restoration off,
ran 30 interleaved baseline/speculative pairs per available snapshot. Each condition
started from the same warm fixed prefix and used the saved prompt and dictionary only
in RAM. The mock reused completed speculative output only for an exact raw transcript
and unchanged settings; otherwise it ran authoritative final cleanup. Trimmed outputs
matched across all pairs. Release savings combine measured Gemma time with the single
ASR snapshot's lead time; no concurrent ASR/Gemma, microphone or visible-text timing was
measured. Report: ignored `bench/results/speculative-cleanup.json` (harness `bfef7f6`).

| Snapshot | Exact final match | Median extra/wasted Gemma work | Projected median release saving |
|---|---:|---:|---:|
| Ordinary correction, first partial | No | 91 ms | 1.9 ms |
| Ordinary pause, first partial | No | 92 ms | 3.3 ms |
| Extended correction, first partial | No | 94 ms | 1.6 ms |
| Extended correction, late partial | Yes | 135 ms generation | 134 ms |
| Extended short, first partial | Yes | 130 ms generation | 131 ms |

The exact-match rows move cleanup into the user's silent hold, rather than reducing
total work. A separate 30-run stress probe submitted a stale partial and, 5 ms later,
the authoritative final request to the same Gemma slot. All 30 finals succeeded and
matched baseline output, but release-to-final response was 173 ms median / 182 ms p95,
versus 94 ms median / 111 ms p95 for the correction baseline without overlap. This
shows a real contention penalty if speculation remains active near release; it is not
a full app latency comparison.

Decision: no app integration. The current app uses batch ASR, while the paced streaming
adapter was slower on the ordinary under-five-second clips and emitted no useful exact
early partial in them. A 2-second streaming initial window, wasted full generations and
same-slot contention outweigh this mock's silent-tail opportunity for common dictation.
The temporary server stopped on exit; the installed cleanup service was not replaced.

## Chrome media resume

10 October 2026: the user's debug log showed every Chrome dictation as `issued`, then
`skipped/itemChanged` on the first update, already paused and before any `paused`
confirmation, then `noLease` at release, so Chrome stayed paused. Spotify, whose paused
update keeps comparable metadata, resumed. The broker now accepts a new opaque item ID from the same
player process on the update that confirms its own pause, unless track metadata
contradicts it; after confirmation the check stays strict. Two synthetic broker tests
cover an ID minted at pause (no metadata, no artist/album, 0.4 s duration change) and a
contradicting title at pause; the existing strict-ID tests pass unchanged. After the
rebuild, the user confirmed Chrome resuming on two physical dictations; the log shows
`itemIdentifierRefreshed`, `paused` and `released` for both. The broker's 40 ms
post-Play check still reported `resumeUnconfirmed` for both (diagnostic only; Play was
submitted and playback resumed).

## Hold-time ASR keep-warm

10 October 2026: 48 logged real dictations (old capture path) had median ASR 217 ms and
127 to 134 ms even for 2 s clips right after the previous dictation, against 59 to 98 ms
in back-to-back synthetic runs. A temporary release-build probe with the cached Ultra
model then measured a 2.7 s synthetic clip after varying idle gaps (8 rotated repetitions)
and a synthetic 4 s hold after 2 s idle, followed by the 4.2 s clip at release (5 rotated
repetitions per condition). The user's app stayed running; no audio or text was recorded.

| Idle before ASR | Median | p90 |
|---|---:|---:|
| 0 / 0.1 / 0.25 / 0.5 s | 78.7 / 79.1 / 85.8 / 87.1 ms | 84.1 / 114.9 / 107.2 / 115.8 ms |
| 1 / 2 / 4 s | 118.6 / 120.1 / 119.8 ms | 126.2 / 161.4 / 188.1 ms |

| 4 s hold | Release to final ASR median | p90 |
|---|---:|---:|
| No passes | 147.3 ms | 151.6 ms |
| Pass every 0.25 / 0.5 / 1.0 s | 92.2 / 88.9 / 88.9 ms | 93.4 / 161.7 / 114.8 ms |

A held pass (1 s silence) took 76.1 ms median, about the same as transcribing the 2.7 s
clip, so a pass costs roughly one short transcription. The app now passes every 500 ms
while held and never between dictations. The probe was removed. Physical release-to-text
gain and power use remain to be confirmed from debug logs. `make check` passed with 83 Swift
tests in 24 suites, including a hold that repeats passes and stops them at release.

## Local dictation history

11 October 2026: **Keep dictation history on this Mac** (Cleanup page, on by default) saves
completed batch raw/cleaned pairs locally as training data for the cleanup model. `make test`
passed with 88 Swift tests in 25 suites plus broker, setup and release tests. New tests cover
the default for new and old preferences, 0700/0600 modes, backup exclusion, the prompt kept
only as a fingerprint, disabled and deleted states, rotation keeping the newest entries in
order, a file error that stops saving without blocking the caller, and a coordinator that
saves a completed dictation but not a cancelled one. All test text is synthetic. Physical
dictation into the real history file and training use remain unverified.

## Fitted settings layout

11 October 2026: settings no longer need scrolling. The window is 640 points wide and its
height follows each page with the top edge fixed; rows are grouped with captions on the
left and controls on the right; the prompt and dictionary editors scroll inside and resize
by a drag grip. Demo output no longer has a Settings switch; it remains a visibly marked
`preferences.json` development mode. Synthetic `--ui-preview` renders, isolated from the
user's saved editor heights, fit every page between 613 and 738 points: General 683 (635
for HTTP), Cleanup 738, Advanced 703 (613 for HTTP), in light and dark. At a 560-point
short screen the content scrolls and Save stays visible. A real titled window fitted its
content to the 613-point HTTP Advanced page with its top edge unchanged. Permission buttons
are no longer truncated. In the installed app the user resized the dictionary editor, which
persisted at 292.5 points. Live tab switching and accessibility in the running app still
need a manual look.

## VAD silence-trimming prototype

11 October 2026: `whispr-bench --vad-trim-prototype` ran FluidAudio 0.17.7's Silero
`silero-vad-unified-256ms-v6.2.1` on CPU only (threshold 0.5, negative 0.35) over the eight
synthetic WAVs, the four base clips under five seconds joined by 2 s pauses over a quiet
synthetic noise floor, and 3 s of that noise alone. Edge trimming keeps first to last
speech; pause trimming also shortens pauses of at least 0.75 s, keeping 0.25 s padding.
Batch Unified ran 30 rotated rounds per original/edges/pauses variant with the app closed;
both models were prepared outside timing. Results: ignored `bench/results/vad-trim.json`.

| Synthetic fixture | Audio → pause-trimmed | Windows | VAD pass median | ASR original / trimmed median | Paired ASR saving | Projected net, VAD at release / during hold |
|---|---:|---:|---:|---:|---:|---:|
| Short | 0.96 → 0.96 s | 1 → 1 | 0.9 ms | 59.0 / 59.1 ms | 0.0 ms | -0.8 / -0.2 ms |
| Short + trailing silence | 3.66 → 1.27 s | 1 → 1 | 3.2 ms | 63.7 / 59.7 ms | 4.4 ms | 1.2 / 4.2 ms |
| Correction | 2.66 → 2.66 s | 1 → 1 | 2.3 ms | 66.1 / 66.4 ms | -0.7 ms | -2.9 / -0.9 ms |
| Correction + trailing silence | 4.46 → 2.81 s | 1 → 1 | 3.7 ms | 68.4 / 65.7 ms | 3.0 ms | -0.7 / 2.8 ms |
| Dictionary | 2.32 → 2.32 s | 1 → 1 | 2.1 ms | 68.5 / 68.7 ms | 0.0 ms | -2.2 / -0.2 ms |
| Sentence with pause | 4.19 → 3.16 s | 1 → 1 | 3.6 ms | 71.6 / 69.5 ms | 2.1 ms | -1.6 / 1.8 ms |
| Eight-second container | 8.00 → 5.63 s | 1 → 1 | 6.9 ms | 91.9 / 88.9 ms | 3.8 ms | -3.0 / 3.6 ms |
| Twenty-five-second container | 25.00 → 19.19 s | 2 → 2 | 20.7 ms | 248.9 / 238.3 ms | 9.9 ms | -10.8 / 9.7 ms |
| Joined clips, 2 s pauses | 16.14 → 10.97 s | 2 → 1 | 13.6 ms | 173.6 / 109.4 ms | 64.5 ms | 50.9 / 64.3 ms |
| Noise only | 3.00 s → no speech | 1 → 0 | 2.6 ms | 58.6 ms / skipped | 58.6 ms | 56.1 / 58.4 ms |

VAD cost about 0.21 ms per 256 ms chunk and repeated exactly in every run. Unified pads
each recording to its fixed 15 s encoder window, so within one window trimming saves only
decoder frames (at most 4.4 ms here); a full VAD pass at release cancels most of that,
and VAD during the hold would leave a few milliseconds. Only removing a whole window paid
off (64.5 ms on the joined fixture); the 25 s container stayed at two windows. On noise
alone Parakeet already returned empty text, so the existing pipeline already skips cleanup.

Words matched the original in every variant; punctuation changed in four fixtures.
Trailing digital silence dropped the final full stop in the correction and eight-second
containers and trimming restored it; the short clip with trailing silence became
"Hello, world" (untrimmed "Hello world", clean clip "Hello world."); the joined fixture
gained sentence punctuation. Fixture padding is digital zero, not room noise, and
cleanup was not run, so this is not an accuracy result.

Not integrated. For the roughly 99% under-five-second workload the projected gain is
under 5 ms, while integration would add a model asset, readiness/provisioning, VAD
work alongside capture and a punctuation change. If long dictations with long pauses
become common, the candidate is VAD only for recordings over 15 s, used only when it
removes a window. Physical noise floors, real pauses and the effect on cleanup output
remain unmeasured.

## Low-latency capture and read-driven clipboard restore

10 October 2026: a content-free probe on this Mac's default input (44.1 kHz mono) showed
the sink node delivering 512-frame cycles every 11.6 ms with valid sample and host times,
against 4,410-frame tap packets. A temporary probe then timed the release drain (release
boundary to finalized PCM) over two alternating passes of 12 warm trials per path. The test
process had no microphone authorization, so input was silent, but delivery timing came from
the real device:

| Path | Median | Min | Max | Late drains |
|---|---:|---:|---:|---:|
| Tap (former) | 61.6 / 57.9 ms | 13.9 / 11.0 ms | 115.8 / 106.2 ms | 0 |
| Sink node | 9.0 / 9.7 ms | 4.2 / 7.7 ms | 16.8 / 14.7 ms | 0 |

The probe was removed after measurement and no audio was written. Synthetic tests cover
sink-callback timestamps, release trimming, a missing I/O cycle failing rather than
splicing, and a 1.4 s worker stall absorbed by the 128-slot pool. Clipboard tests cover a
target read restoring after the grace period rather than the fallback, stale read callbacks,
transient markers and a native promised-text read. `make check` passed: 82 Swift tests in 24
suites plus native broker, setup and release tests, signed app, doctor and smoke check.
Not measured: speech through the signed app, Bluetooth or USB microphones on the sink path,
release-to-visible latency, and clipboard restore timing in third-party apps or with
clipboard managers running.

## Capture, setup and cleanup robustness pass

10 October 2026: slot sizing from the hardware rate, a lock-free callback slot handoff,
non-fatal late release drain, route-change capture rebuild, visible not-ready presses,
idle Escape no-op, capture before the AX snapshot with a 1 s AX timeout and batched
validation attributes, prepared-model reuse across setup, a shared HTTP session, a
proportional cleanup output limit and skipping the cleanup preflight when a byte bound
proves the prompt fits. New synthetic tests cover 96/192 kHz packets, pool exhaustion and
slot return, a late release packet, not-ready presses, idle Escape, capture-before-snapshot
order, the proportional output limit and the skipped preflight. The diagnostics rotation
test previously failed 4 of 24 isolated runs on the unchanged tree because record sizes vary
with uptime digits; it now accepts the record in either rotated file.

`make check` passed: 77 Swift tests in 23 suites, 14 native broker tests, 14 setup tests,
4 release-tooling tests, signed arm64 app with no compiler warnings, doctor and bundle
smoke check. Not measured: real route changes, Bluetooth or high-rate microphones, AX
timing in third-party apps, cleanup latency saving in the app, or release-to-visible latency.

## Acoustic release-to-visible validation attempt

10 October 2026: an opt-in finite signed-app benchmark was added to play a synthetic
phrase through a named CoreAudio output while the normal configured microphone,
ASR, cleanup and native benchmark text field run. It invokes coordinator press/release
inside the app, so physical key delivery and display-compositor visibility remain
outside its span. Only timing stages and a phrase-match boolean would enter the ignored
report; no microphone audio or recognised text is persisted.

The initial pilots exposed a capture defect before playback: the 44.1 kHz input tap
delivered 4,410-frame packets even though it requested 512 frames. The fixed callback
pool accepted at most 4,096 frames; three successive press attempts failed with
`overflow`. Increasing each of the 16 preallocated slots to 8,192 frames retains bounded
callback work and accepted the observed packet. A synthetic 4,410-frame regression
verifies warm capture and conversion. After the fix, a signed pilot reached capture
finalization and ASR with 27,327 owned samples and no capture failure.

The acoustic loop did not produce usable speech. Pilots through the built-in speaker,
display output and selected external output all returned no visible text; the first
fixed-path run recorded an empty ASR result, so it could not measure cleanup or
release-to-visible latency. A separate in-memory AVFoundation level probe reported
-91 dB with and without synthetic playback. That probe may have different microphone
permission or echo-cancellation behavior from the signed app; it does not establish the
cause of the empty result. No pilot is counted as a successful latency observation.
No audio or transcript was written to disk.

`make check` passed with normal session access: 71 Swift tests in 22 suites, 14 native
broker tests, 14 setup tests, 4 release-tooling tests, signed arm64 app, doctor and
bundle smoke check. A sandboxed attempt failed one native test; the full permitted
rerun passed. A further signed synthetic native-flow attempt lost destination focus on
its first fixture and produced no new report. Prior diagnostic logs contain 36
release-to-insertion-dispatch spans (629 ms median, 1,415 ms p95), but mix earlier
sessions/configurations and do not establish visible text or current-build latency.

The 30+ real release-to-visible stage benchmark remains open. It needs a verified
microphone speech source or controlled input route, followed by actual text-update
observations; this attempt neither confirms nor rejects the long-idle warm-up benefit.

## Press-time ASR warm-up prototype

Historical measurements from commit `58b318f`. The one-shot prototype harness was
retired after hold-time keep-warm shipped; these figures do not validate the current
periodic hold behavior.

10 October 2026: the pinned Unified batch backend was prepared from cached models,
then tested on two synthetic clips. Each observation had a one-second idle interval
before simulated press and 40 ms ticks during the audio-length hold. Alternating
baseline and candidate observations ran 30 times per clip. The candidate started one
16 kHz, one-second silence inference at press, awaited its settlement at release, then
ran the same final batch transcription. Outputs matched exactly in all 120 final runs.
This excludes microphone capture, Gemma, insertion and energy measurement. A first
two-run pilot with one long sleep overshot nominal release and was discarded; the
corrected 40 ms tick run had median release lag under 3 ms.

| Synthetic clip | Baseline release → ASR median / p95 | Press warm-up median / p95 | Paired median saving | Paired wins |
|---|---:|---:|---:|---:|
| 0.96 s short | 169 / 306 ms | 164 / 301 ms | 8 ms | 18/30 |
| 2.66 s correction | 176 / 307 ms | 172 / 312 ms | 2 ms | 16/30 |

The extra silence inference cost about 160 ms median at press for both clips; it was
settled before release in all repeated observations. The broad, bimodal final ASR
distribution remained in both conditions, so the two-run pilot's larger apparent gain
did not repeat. Report: ignored `bench/results/press-warmup.json`. A 90-second idle
spot check used two paired observations per clip, so it is exploratory:

| 90 s idle clip | Baseline release → ASR | Press warm-up release → ASR | Paired savings |
|---|---:|---:|---:|
| 0.96 s short | 209, 193 ms | 119, 135 ms | 90, 57 ms |
| 2.66 s correction | 206, 219 ms | 177, 161 ms | 29, 58 ms |

All four pairs improved and retained exact synthetic output. The extra silence inference
took 147–188 ms before release. Reports: ignored `bench/results/press-warmup-idle90.json`
and `bench/results/press-warmup-correction-idle90.json`. This prompted a conditional
implementation after 90 seconds without ASR activity, with no timer or polling. The
warm-up runs away from the event-tap callback, is allowed to settle rather than being
cancelled mid-CoreML, and is awaited before final ASR and model replacement. Four
long-idle pairs do not establish a general latency or battery benefit; physical
recording, 5/25-minute idle and power checks remain open.

After integration, `make check` passed with normal session/keychain access: 70 Swift
tests in 22 suites, 14 native broker tests, 14 setup tests, 4 release-tooling tests,
arm64 signed app build, doctor and bundle/resource smoke. The focused lifecycle test
cancelled one press, immediately retried, and verified the pending warm-up settled
before final ASR with only one inserted result. The initial sandboxed `make test` run
failed three native pasteboard/modifier tests because of restricted session access;
the permitted normal-session rerun passed them. The signed build has not yet had a
physical push-to-talk or measured release-to-visible-text trial.

The rebuilt signed app was relaunched in the background; startup diagnostics recorded
`preparationReady` in 649 ms and `readiness=ready` at 17:43 UTC.

## Small Unified / Ultra comparison

Three existing Samantha synthetic clips, 30 warm runs per clip per model (180 measured
observations total), through the actual batch adapter. The normal app was closed; no
build or download ran during measurement. Unified ran first, then Ultra, with one model
loaded at a time. This is a small exploratory comparison with no interleaved model order,
real speech, noise, memory-pressure or physical dictation measurement. Medians below use
both middle observations; raw samples are retained in ignored reports.

| Clip | Unified median / p95 | Ultra median / p95 |
|---|---:|---:|
| Short, 0.96 s | 61.40 / 72.66 ms | 55.60 / 59.30 ms |
| Correction, 2.66 s | 73.59 / 128.67 ms | 60.54 / 68.58 ms |
| Eight-second container | 97.86 / 125.30 ms | 90.93 / 101.11 ms |

Both models produced repeat-consistent output and passed empty/silence, cancellation /
settlement / reuse and unload / reprepare checks. Ignoring case and punctuation, Unified
matched all three synthetic references; Ultra matched two. On the longer clip Ultra
substituted “a report” for “the report”. These clips do not establish a general accuracy
ranking. Unified remains selected by default; the user can now try Ultra independently.

Download was separate from measurement. The first Ultra preparation on this machine
took 19.58 s; the already-prepared Unified stack took 0.29 s. First-use CoreML work and
unequal prior cache state make those preparation numbers unsuitable as a general loading
comparison. The verified 632,318,254-byte Ultra snapshot comes from
`FluidInference/parakeet-ultra-coreml`, revision
`95eaa59a39d4394f047a4dc5cce480388a60d1b6`. Every file matched its repository size and
LFS SHA-256 or Git blob ID, then SHA-256 after cloning into the owned app cache.
Existing Unified models, shared caches, cleanup service and private settings were preserved.

Reports: `bench/results/model-unified.json`, `model-ultra.json`, `model-comparison.json`
and `ultra-download.json`. The comparison contains synthetic transcripts only. An initial
sandbox-restricted CoreML attempt was stopped and excluded; the recorded runs used normal
CoreML access. Broader hardware/accuracy/performance acceptance remains open.
The final signed bundle prepared cached Ultra, accepted short synthetic input and unloaded
successfully. Its normal Launch Services probe reports Unified, all three permissions,
pipeline and event tap ready (`bench/results/readiness-model-picker.json`). The app's
settings were reopened; neither probe exercised a physical hotkey or visible insertion.

## General cleanup default

The bundled default is 1,723 characters, compared with 2,592 in the saved imported
prompt. It contains no personal context. `Use default prompt` changes only the settings
editor; saving applies the change. Existing private text and the input format were
preserved. The resource and code fallback match. The signed rebuild passed `make check`
(60 Swift, 14 broker, 14 setup), all sixteen synthetic native renders completed, and the
Launch Services probe reports granted permissions, ready ASR/cleanup and a ready event
tap. The normal app was reopened with its existing Right Control/debug preferences.
Readiness report: `bench/results/readiness-prompt-default.json`.

The real standalone Gemma/MTP service checked 18 public synthetic cases with a public
dictionary. Word, empty-output, question and line-break criteria are in
`bench/prompt-fixtures.json`; this is a small regression set, not a full accuracy review.
The saved prompt passed 16/18 with plain input and 15/18 with transcript tags. The general
default passed 18/18 plain and 17/18 tagged (one paragraph-break failure). Adding one
short private context line passed 18/18 with both formats. These were single-pass checks;
the separate 24-case historical corpus still has no reviewed expected outputs.

`scripts/bench-prompts.py` then measured 720 observations: 30 for each of four short
synthetic inputs, each prompt and each cache mode. Timing includes the app's template,
token-count and completion requests, using the actual private dictionary and tagged
framing. Conditions were interleaved; warm blocks were primed separately. The disabled
prompt-cache condition confirmed zero reused tokens. Output repeats were consistent
within each condition, cache mode and case.

| Prompt | Prefix cache | Median | p90 | p95 |
|---|---|---:|---:|---:|
| Saved imported | Disabled | 1,076.42 ms | 1,129.10 ms | 1,181.76 ms |
| General default | Disabled | 888.64 ms | 974.24 ms | 1,058.88 ms |
| Default + private context | Disabled | 907.13 ms | 1,018.16 ms | 1,087.53 ms |
| Saved imported | Warm | 174.90 ms | 187.39 ms | 195.82 ms |
| General default | Warm | 161.06 ms | 184.76 ms | 190.78 ms |
| Default + private context | Warm | 169.29 ms | 184.79 ms | 189.16 ms |

With the context line, the measured median saving is about 169 ms when the whole prompt
is processed and 6 ms when its prefix is reused. The small warm difference is not a
universal speedup claim. All conditions used warm model weights; this does not measure
model loading, long idle, ASR, physical capture or visible insertion. The ignored report
`bench/results/prompt-review.json` contains metrics and synthetic case IDs only; privacy
checks confirmed no saved prompt, dictionary, context or generated text in it.

The Swift tests also cover session/generation ownership, late cancellation, single release
and safety finalization, busy/hotkey/repeat/injected events, 16/44.1/48 kHz conversion,
pre-roll and accepted-release tail trimming, WAV/multipart framing, bounded HTTP/context/
truncation handling, raw-result recovery, actual named-pasteboard multi-item restoration,
clipboard ownership, streaming final-only insertion and cancellation, retained-audio
fallback, coalesced prefill and old private-preferences migration. Setup tests never write
real login items/settings, download models or use private data.

Permission-enabled startup exposed a Swift 6 isolation crash in the AVAudioEngine tap:
a closure created inside MainActor `prepare` was invoked on the audio queue. The callback
is now built as an explicitly Sendable function outside MainActor isolation, with a
regression check invoking the production callback off-thread and reusing the source buffer
after return. Normal signed startup/readiness is checked through Launch Services because
direct execution from the tool can attribute permissions to its invoking process.
Lock/sleep/session-loss now cancels preparation, invalidates its epoch, stops the hotkey,
capture and media, and hides feedback. A startup at the observed login window remains
paused, so a late preparation cannot make a locked session ready. Full physical lock/
wake/hotkey acceptance remains a separate gate.
The final signed locked-startup probe passed: `ready=false`, pipeline/event tap inactive,
status “Dictation paused”, all three permissions still granted. Its report is in ignored
`bench/results/readiness-locked.json`; Settings was reopened for the user.

Raw content-free native timing observations are in ignored `bench/results/batch-flow.json`.
The successful initial run recorded combined pipeline and result-to-native update spans.
The check now also records ASR/cleanup spans, but its rerun was blocked by the lock screen
and correctly refused insertion. Unlock/focus is required to collect those new spans.
These measurements exclude physical capture/drain/release, compositor latency and other
destination apps. The long
25-second container contains about 19 seconds of speech and misses the plan's
~300–550 ms warm batch target. It remains an explicit performance gate, not a passed target.
The eight-second container contains about 5.5 seconds of speech. Synthetic repeat equality
is not reviewed ground-truth accuracy; all 24 cleanup expected outputs remain unset.

| Synthetic fixture | Warm count | Native update median | p90 | p95 |
|---|---:|---:|---:|---:|
| Short | 30 | 271.63 ms | 312.72 ms | 326.50 ms |
| Correction | 30 | 336.38 ms | 382.24 ms | 399.00 ms |
| Dictionary | 30 | 398.94 ms | 425.20 ms | 438.28 ms |
| Pauses | 30 | 347.56 ms | 378.68 ms | 419.92 ms |
| Eight-second container | 30 | 551.41 ms | 587.47 ms | 589.20 ms |
| Twenty-five-second container | 30 | 1084.50 ms | 1150.88 ms | 1172.83 ms |

These initial samples were collected during integration work with some build activity.
The isolated rerun with separate ASR/cleanup spans remains pending unlock/focus.

The installed OpenWhispr provider differs from the historical tuned server documented in
[the historical notes](bench/HISTORICAL_NOTES.md). Exported prompt/framing and a controlled output-budget comparison are checked;
historical provider/output parity is not established. The first cold cleanup probe took
1578 ms, separately from warm observations. 90-second/5-minute/25-minute idle, memory
pressure, physical footprint, wakeups/power and daily-use trials remain pending.

`stack.lock.json` records macOS 27.0/build 26A428, Swift 6.2.3, SDK 26.2, published core/media
revisions and ASR hashes; `Resources/cleanup-stack.json` records the verified cleanup
assets/runtime. Owned ASR caches were cloned from synthetic benchmark assets into the
workspace and private application-support directory; shared/default caches were untouched.
Initial timings used the Homebrew cleanup binary, which requires macOS 26+.
The current standalone release uses the same revision and declares macOS 13.3 minimum;
its synthetic output parity is checked, but those timings were not remeasured for it.
The app targets 14+. Other-machine/older-macOS provisioning and notarization remain open.

The previous media state probe observed unknown/no active player: median one-shot read
24.43 ms versus persistent round trip 0.093 ms. This is a read-only protocol comparison,
not observed pause/resume effect or real-player/resource acceptance. No titles/artwork/
playback history are emitted. Raw results are in ignored `bench/results/media-probe.json`.

## Smaller cleanup model comparison: 11 October 2026

Read 79 completed raw/cleaned transcript pairs from the local OpenWhispr SQLite history
immutably. Ran the installed pinned Gemma 4 E2B/MTP service as baseline, then each
candidate alone on an isolated 11437 Metal server. Real inputs used the saved private
prompt, dictionary and OpenWhispr framing; the 28 public synthetic cases used the
bundled default prompt and public dictionary. All models used non-thinking mode,
temperature zero and the app's proportional output cap. Every real request completed.

| Cleanup model | GGUF file | Public synthetic pass | Exact to Gemma on 79 real inputs | Exact to historical cleaned text |
|---|---:|---:|---:|---:|
| Gemma 4 E2B QAT Q4 + 59 MB MTP | 2.62 GB | **26/28** | baseline | 23/79 |
| Qwen3.5 2B Q4_K_M | 1.28 GB | 19/28 | 37/79 | 22/79 |
| Qwen3 1.7B Q4_K_M | 1.11 GB | 17/28 | 36/79 | 24/79 |
| Gemma 3 1B QAT Q4_K_M | 0.81 GB | 17/28 | 30/79 | 18/79 |
| Qwen3.5 0.8B Q4_0 | 0.56 GB | 16/28 | 34/79 | 24/79 |

The model files were SHA-256 verified from pinned revisions:
[Qwen3.5 2B](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/tree/f6d5376be1edb4d416d56da11e5397a961aca8ae),
[Qwen3 1.7B](https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/tree/7fb011e9aee6e4dc7adf8430df9ea8de6a466aa3),
[Gemma 3 1B](https://huggingface.co/bartowski/google_gemma-3-1b-it-qat-GGUF/tree/074329a7942d6a61a3748a80ed1bbc9e2d7d0e18) and
[Qwen3.5 0.8B](https://huggingface.co/ggml-org/Qwen3.5-0.8B-GGUF/tree/8fea620810c4afa23dd6443f999a48574c1611a3).
In the 23 real cases where Gemma exactly matched the historical cleaned text,
Qwen3.5 2B matched 19, Qwen3 1.7B matched 21, Gemma 3 1B matched 16 and Qwen3.5
0.8B matched 19. The 79 historical outputs are another model's cleanup, not human
reviewed truth. This is a single-pass quality screen; it does not establish a real
error rate or prove that any disagreement is wrong. The synthetic cases reveal
specific gaps in self-correction, filler removal, paragraph breaks, British spelling
and multilingual punctuation. In a separate exploratory run using the saved dictionary,
a shorter prompt reduced the synthetic pass count for Qwen3 1.7B from 20 to 15 and
Qwen3.5 2B from 19 to 17, so it was not adopted.

Ignored aggregate reports: `bench/results/cleanup-models-final.json` and
`cleanup-models-followup.json`. No private transcript, prompt, dictionary or generated
text was saved in them; model weights remain in ignored `.build/`. The installed
service/settings were unchanged, and temporary servers stopped. Completion-only warm
timings and one post-run candidate-server RSS sample are in the report, but neither
includes ASR, insertion, model cold start or memory pressure. Measure an 8 GB Mac and
review real disagreements before offering a smaller model as a supported choice.

### Liquid AI cleanup follow-up: 11 October 2026

Used the same 79 real pairs, 28 public synthetic cases, prompt/framing, temperature
zero, output cap, pinned llama.cpp b10809 and isolated 11437 Metal server as above.
All GGUF SHA-256 hashes matched their pinned Hugging Face revisions. Results are
single-pass and cleanup-only; real exact matches are against model outputs, not
human-reviewed truth.

| Liquid model | GGUF file | Real completed | Public synthetic pass | Exact to Gemma on completed real inputs | Warm median cleanup call | Candidate RSS after run |
|---|---:|---:|---:|---:|---:|---:|
| LFM2.5 1.2B Instruct QAD Q4_0 | 0.70 GB | 78/79 | 15/28 | 26/78 | 303 ms | 827 MiB |
| LFM2.5 1.2B Instruct Q4_K_M | 0.73 GB | 75/79 | 11/28 | 16/75 | 356 ms | 858 MiB |
| LFM2 2.6B Q4_K_M | 1.56 GB | 78/79 | 17/28 | 21/78 | 874 ms | 1,674 MiB |
| LFM2.5 2.6B Q4_K_M | 1.67 GB | 0/79 | 0/28 | n/a | n/a | 1,804 MiB |

Gemma repeated at 26/28 and about 279-310 ms median across these two passes.
The LFM2.5 2.6B row is a compatibility failure under the current app output cap,
not a measured correctness score: all 79 real requests ended at the length limit.
Liquid [describes it as always reasoning before answering](https://huggingface.co/LiquidAI/LFM2.5-2.6B),
and a public-only probe confirmed the cap was spent on reasoning with no final text.
The LFM2.5 1.2B QAD checkpoint performed better than its ordinary Q4_K_M quantization,
but missed synthetic dictionary, filler-only, paragraph, British spelling and
multilingual punctuation cases. Neither smaller model matched Gemma's task quality.

Verified model revisions:
[LFM2.5 1.2B Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/tree/8ed288026e23958ad9dfa92d53ed773a8eee7125),
[LFM2.5 2.6B](https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/tree/e7caca5d835a3901a8e0d63e94009429bafafdfc), and
[LFM2 2.6B](https://huggingface.co/LiquidAI/LFM2-2.6B-GGUF/tree/a759abdc5955d4ca97763e5cb7ff3940589ba898).
Liquid's [LFM Open License v1.0](https://www.liquid.ai/lfm-license) requires
distribution notices and has a $10 million annual revenue threshold for free
commercial use; review those terms before shipping a model choice. Aggregate-only
reports are ignored at `bench/results/cleanup-liquid.json` and
`bench/results/cleanup-liquid-lfm2.json`; weights remain under ignored `.build/`.
No installed service or settings were changed. Low-RAM memory pressure and reviewed
real-output accuracy remain open.

### Further low-RAM cleanup screen: 11 October 2026

Checked two more compact GGUFs, a smaller quantization of the existing Gemma 4
E2B QAT model, and Apple's built-in Foundation Model. The same 79 real inputs and
28 public synthetic cases were used. The GGUF runs kept the installed Gemma
baseline, prompt, dictionary, framing, generation cap and pinned llama.cpp runtime;
Apple used the same prompts and proportional output cap with greedy generation via
`FoundationModels`. Gemma repeated at 26/28 synthetic and 79/79 real completed.

| Candidate | Model file | Real completed | Public synthetic pass | Warm median cleanup call | Finding |
|---|---:|---:|---:|---:|---|
| Apple on-device Foundation Model (macOS 27) | OS-managed | 78/79 | 16/28 | 2,256 ms | Available on this Mac, but slower and less accurate under this prompt |
| Granite 4.0 1B Q4_K_M | 1.02 GB | 0/79 | n/a | n/a | Pinned runtime generated repeated `@` characters and hit the output cap |
| Ministral 3 3B Instruct Q4_K_M | 2.15 GB | 79/79 | 17/28 | 533 ms | Larger and less accurate than Qwen3.5 2B in this screen |
| Gemma 4 E2B QAT Q2_K_XL | 2.19 GB | 79/79 | 17/28 | 297 ms | Saves 0.43 GB of weights but loses nine synthetic cases versus installed Q4 |
| Qwen3.5 4B Q3_K_M | 2.29 GB | 79/79 | **24/28** | 838 ms | Closest smaller GGUF to Gemma's task score, with modest memory savings |

Granite's row is a runtime compatibility failure, not a quality result. Its
public-only diagnostic request emitted 128 `@` characters with `finish_reason=length`.
Ministral's real outputs exactly matched Gemma in 10/79 cases; lower-bit Gemma in
23/79; Apple's in 19/78 completed cases. These are disagreements, not reviewed
correctness judgments. Qwen3.5 4B Q3_K_M exactly matched Gemma in 27/79 real
cases and the historical cleaned text in 21/79; these are comparison references,
not truth. It missed public filler-only, paragraph, emphatic-repetition and
Spanish-question cases. Its post-run server RSS was 2,762,112 KiB versus about
2,992,528 KiB for the installed Gemma process, a roughly 225 MiB saving on this
Mac. The 2.29 GB file is 0.33 GB smaller than Gemma's model file, or about 0.39 GB
smaller than Gemma plus MTP. Qwen3.5 2B remains the larger memory reduction at
1.28 GB and 19/28 synthetic, with a clearer quality cost.

Apple's model required normal macOS model-service access; the restricted session
returned a model-service error. Its use requires [Apple Intelligence availability and
macOS 26+](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).
It avoids a separate model download, but OS-managed RAM use and 8 GB memory pressure
were not measured, and model updates can change behavior. A task-specific prompt may
alter results; the current saved prompt was used for direct comparison.

The GGUFs were SHA-256 verified from these pinned revisions:
[Granite 4.0 1B](https://huggingface.co/ibm-granite/granite-4.0-1b-GGUF/tree/b27c2fe3f211b7f44e80fa620177aea371099aaa),
[Ministral 3 3B](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/tree/eb599d408350ea2bb60452cb86be7c7b2fc28227),
[Gemma 4 E2B QAT](https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/tree/66a399f68ddd113b06dff02fca9523e55465d11d), and
[Qwen3.5 4B](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/tree/e87f176479d0855a907a41277aca2f8ee7a09523).
Aggregate-only reports are ignored at `bench/results/cleanup-apple-foundation.json`,
`cleanup-granite-ministral.json`, `cleanup-gemma-q2.json` and
`cleanup-qwen35-4b-q3.json` (Apple harness `1c58515`). Model weights and the
compiled Apple benchmark bridge remain in ignored `.build/`; no private transcript,
prompt, dictionary or generated text was saved in reports. The installed Gemma
service and settings were unchanged. Human review of real disagreements and memory
testing on a constrained Mac are still needed before adding a supported alternative.

## MTP plus n-gram speculation and long-dictation chunks: 11 October 2026

The pinned llama-server b10809 starts with `--spec-type draft-mtp,ngram-simple`,
`draft-mtp,ngram-map-k` and `draft-mtp,ngram-mod`. All six 3-/4-token lookup variants
completed 50/50 public synthetic requests with exact trimmed output parity against
MTP alone. Each ran on an isolated port 11437 with the pinned Gemma/MTP weights,
the bundled default prompt and a public dictionary; the installed service was unchanged.
The sandbox could not create a Metal command queue even for unchanged MTP, so actual
runs used normal session access. The first timing pass varied enough to warrant a
focused 30-repetition comparison of `ngram-mod` at a 4-token match, with MTP passes
before and after. All three focused conditions completed 150/150 and matched exactly.

| Public synthetic input | MTP before / after median | MTP + ngram-mod4 median |
|---|---:|---:|
| Short question, 5 words | 85 / 87 ms | 83 ms |
| Short correction, 8 words | 164 / 168 ms | 127 ms |
| Short instruction, 8 words | 126 / 129 ms | 167 ms |
| Mixed passage, 82 words | 1,134 / 1,160 ms | 806 ms |
| Repeated copy passage, 140 words | 230 / 242 ms | 212 ms |

For the mixed passage, MTP accepted 2,610/4,320 drafted tokens across 30 requests;
the combination accepted 2,810/3,878. The same combination slowed one short input
by about 40 ms, so it is not a general win for common short dictations. No service
setting was adopted. Results are warm cleanup HTTP calls with public text, one server
mode loaded at a time; they exclude ASR, capture, insertion and physical contention.
Reports: ignored `bench/results/ngram-cleanup.json` and
`bench/results/ngram-cleanup-followup.json` (harness `4b97c28`); neither stores model output.

For a separate 25 s public synthetic dictation, split the WAV at a quiet point at
14.45 s. Thirty warm Unified batch calls per segment had medians of 251 ms full,
143 ms first chunk and 90 ms tail. The first and tail batch transcripts joined to
the same 51-word sequence as full batch. One capture-paced streaming pass emitted
18 partials, but only 10 were exact word prefixes of full batch, and its final
transcript differed by one word. Thus partial text is not yet a safe finished-sentence
boundary or authoritative replacement for batch ASR.

On an isolated pinned Gemma service, 20 cleanup calls each for full, first and tail
transcripts used the saved prompt/dictionary in RAM. Each input produced one repeatable
output; the two cleaned chunks joined to the exact full cleaned output for this fixture.
Median cleanup calls were 535 ms full, 366 ms first and 171 ms tail. If the 143 + 366 ms
first-chunk work finished during the remaining 10.55 s of speech, projected release
work would fall from about 251 + 535 = 786 ms to 90 + 171 = 261 ms, a **525 ms
projection**. These separate calls did not run concurrently with capture/ASR in the app
and did not measure release-to-visible-text. Reports are ignored
`bench/results/long-chunk-batch.json`, `long-chunk-streaming.json` and
`long-chunk-cleanup.json`; only synthetic transcripts appear in ASR reports, and no
private prompt, dictionary or cleanup output was saved. The normal app was reopened;
the installed cleanup service and settings were not changed. Real speech, several
sentence boundaries, chunk overlap/ownership, final output parity and contention
remained open at that point.

The direct Parakeet path now begins speculative chunking after 10 s with a 250 ms
quiet stretch, closing at 15 s at the latest. The worker emits bounded owned PCM;
the coordinator stops hold warming, transcribes and cleans completed sentences during
recording, and verifies their word prefix against final full-audio ASR. An unsafe
boundary falls back to full cleanup. Final ASR, history and insertion still use the
complete recording. Demo/HTTP paths are unchanged.

On the same 25 s public synthetic WAV, the threshold rule cut at 14.51 s. Thirty
warm cached Unified calls measured 254 ms full, 154 ms first chunk and 92 ms tail.
The first chunk ended in a period and its word sequence exactly prefixed full ASR.
The cached-model streaming regression passed on the same three synthetic WAVs. New
capture, cleanup fallback, lifecycle and cancellation tests cover the path. Reports
are ignored `bench/results/early-chunk-asr.json` and `early-chunk-streaming.json`.
These are separate synthetic calls, not integrated release-to-visible-text results.
Real dictations, multiple boundary quality, 10–15 s release contention, output parity
and physical latency remain open.

An exploratory three-call probe against the unchanged installed Gemma service used
the bundled default prompt, a synthetic dictionary and plain input. That differs
from this app's saved custom prompt, dictionary and transcript wrapper. Under the
exploratory request, both full and chunked output dropped opening text, and the two
outputs differed. This result must not be treated as an app-quality observation.

The follow-up used the app's actual saved request configuration without printing or
persisting its private prompt or dictionary. On the 25 s synthetic ASR transcript,
full and chunked cleanup matched exactly: 51 cleaned words, including the opening
ten-word sequence. Across four additional public synthetic composite passages, two
were exactly equal. In the other two, chunked cleanup removed the three superseded
words in a dictated Thursday-to-Friday correction that full cleanup retained. These
five synthetic cases show no observed content loss from chunking, but reviewed real
dictations and integrated release-to-visible-text timings remain open.

The same 14.51 s split was also checked with the user's cached Ultra model (30 warm
calls per WAV, no downloads). Its first chunk ended at a sentence, all 38 first-chunk
words exactly prefixed the 51-word full transcript, and full versus chunked cleanup
with the saved app configuration matched exactly, including the opening. Warm Ultra
batch medians were 237 ms full, 153 ms first chunk and 81 ms tail. The ignored ASR
report is `bench/results/early-chunk-ultra-asr.json`; this still does not measure
physical capture or visible-text latency.

Final validation with normal macOS session access: `make check` passed 93 Swift tests
in 26 suites, 16 broker tests, 14 setup tests and four release tests; it produced a
signed arm64 app, and doctor plus bundle smoke check passed. The cached Unified batch
check and streaming regression above also passed. The installed cleanup service and
app preferences were not changed by these checks.

The pinned FluidAudio TDT path used by Ultra also pads short audio to its fixed
15 s `ASRConstants.maxModelSamples` input. Existing short synthetic results above
show 56–91 ms warm Ultra batch calls. A smaller CoreML encoder export and compatible
library path are needed to measure a shorter window; current cached weights cannot
benchmark that proposed change. It remains lower priority than validating the
long-dictation chunk path.

An encoder-only probe on the M1 Max (64 GB) bounds that saving. The cached Ultra
`Encoder.mlmodelc`, loaded for CPU and Neural Engine with silent 15 s input, had a
41.7 ms median (p90 42.1 ms) over 30 back-to-back calls after five warmups; the
preprocessor took 1.9 ms. After 2 s idle, five single calls took 86–98 ms. A shorter
window can therefore save only part of the warm 42 ms (roughly 25–30 ms if encoder
time scales with input length) on under-five-second dictations, while idle state
roughly doubles the same call. This supports keeping the hold-time keep-warm and
deferring a new export. The temporary probe used no audio or text and was not retained.

## Real dictation timings from the debug log, 11 October 2026

Analysed the content-free debug log on the M1 Max (64 GB) MacBook Pro: 81 dictations
with finalized capture on 10 October 2026, across several development builds, with
Ultra selected from the first configuration record onward. The log holds only stage
times, sample counts and fixed codes; no audio or text was read. Spans end at Command-V
dispatch, not visible text, and the day includes development testing. Earlier tables in
this file come from either this Mac or an M4 Pro, so compare only same-chip results.
`scripts/analyze-diagnostics.py` gives the overall summary; the per-run split, length
distribution and fit below were a one-off analysis of the same fields.

The last two app runs, started after the hold-time keep-warm commit with low-latency
capture on, had 19 complete dictations:

| Stage | Median | p90 |
|---|---:|---:|
| Release → capture finalized | 22.6 ms | 31.0 ms |
| ASR (Ultra) | 133.5 ms | 199.0 ms |
| Cleanup | 244.6 ms | 477.5 ms |
| Result → insertion dispatch | 6.2 ms | 7.0 ms |

Release to dispatch had a 410 ms median. A least-squares fit over the same dictations
gives cleanup ≈ 128 ms + 23 ms per second of audio and ASR ≈ 75 ms + 9 ms per second,
so cleanup is about 60% of the span and grows fastest with length. Capture drain and
dispatch are no longer material.

Recording length across all 81: median 6.0 s, p25 3.3 s, p75 10.1 s, p90 15.6 s; 44%
under 5 s, 43% from 5 to 15 s and 12% at 15 s or more. This differs from the roughly 99%
under-five-second workload assumed by the streaming and VAD decisions above, although
one day of development use is a small and biased sample. Dictations of 15 s or more took
0.9–1.4 s from release to dispatch, which supports the long-dictation chunk work. The
nine capture failures in the log all occurred between 18:12 and 18:16 UTC, before the
hardware-sized tap buffer fix; none followed it.

## Published dictation-cleanup fine-tunes, 11 October 2026

Desk research only; nothing below was downloaded or measured here. Several dictation
apps publish cleanup models fine-tuned on synthetic raw/cleaned pairs:
[Utter E4B](https://huggingface.co/ductai199x/utter-cleanup-e4b) (Gemma 4 E4B, trained
on Parakeet output of TTS speech, Apache 2.0),
[Pigeon](https://huggingface.co/BadXStudio/pigeon-gemma-4-dictation) (Gemma 4 E2B and
E4B, Gemma terms, system prompt unpublished),
[S1-mini](https://huggingface.co/superwhisper/s1-mini) (Superwhisper, Qwen3 0.6B),
[SpeakoFlow Mini](https://huggingface.co/SpeakoFlow/speakoflow-mini) (Qwen3.5 0.8B,
corrections only) and [Fluid-1 Mini](https://huggingface.co/altic-dev/fluid-1-mini)
(Qwen3.5 2B, personal non-commercial use). Their self-reported results favour
fine-tuning over prompting, including much larger models: Utter's tuned E4B needs no
edit on 18.8% of its main set versus 7.2% prompted and 11.3% for prompted Gemma 4
26B-A4B; Pigeon reports 83.2% for E2B and 87.9% for E4B on its own 825 cases. Each uses
its own test set and frozen prompt, so cross-model comparisons are unreliable, and none
would keep this app's prompt (British spelling, private context, dictionary guidance).

Candidate next steps: screen S1-mini, SpeakoFlow Mini and Utter E4B with their own
prompts through `scripts/bench-cleanup-models.py --candidate-prompt`, judged mainly on
the public synthetic cases; or LoRA-tune the installed E2B with the existing prompt.
Training data could combine public sets
([sotto-transcript-cleanup](https://huggingface.co/datasets/juanquivilla/sotto-transcript-cleanup),
142k pairs, MIT; [handy-dictation-editing](https://huggingface.co/datasets/MagicNoThief/handy-dictation-editing),
about 90k pairs, CC-BY-4.0), synthetic speech transcribed by Parakeet and local history.
History targets are the installed Gemma's own output, so they need correction (review
of disagreements with a larger local teacher model) before they can improve on it.
History, the teacher and any model trained on it stay on this Mac and private. A
reviewed, never-trained test set of real dictations is the prerequisite for claiming
an improvement.

Open gates: reviewed cleanup/streaming accuracy and historical parity; first-use ASR
download/default-cache acceptance; physical hotkeys/onset/endings/devices/sleep/lock and
permission denial/revocation/re-sign; full insertion/layout/clipboard matrix; actual Music,
Spotify and Safari/Chromium playback/identity/focus; memory/idle/power and daily-use trial;
fresh-machine installation and rollback acceptance. Real streaming UI and partial-text
prefill remain later work; fixed-prefix warming during preparation is recorded above.
OpenWhispr stays available for rollback; it was not retired or reconfigured.
