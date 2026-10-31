# Accuracy and latency evaluation

Unit tests use synthetic inputs and never download models. Model evaluations are opt-in,
use the production Swift adapters and contact only a local cleanup service. Run them
while dictation and other model work are idle. Reports identify the machine; compare
results on the same machine, runtime, model, prompt and capture mode.

## Reviewed synthetic text

`cleanup-fixtures.json` has 24 agent-reviewed reference outputs. `accuracy-corpus-v1.json`
adds 13 versioned cases covering corrections across chunks, punctuation, independent
sentences, numbers, names, dictionary aliases, French, German and dictated instructions.
These references have not been reviewed by a human. Multiple outputs may be valid;
word-error counts and exact mismatches flag cases for review, not a semantic verdict.
Do not revise an expected output merely because a model disagrees with it.

With the local service already running:

```sh
source scripts/swift-env.sh
WHISPR_EVALUATE=1 WHISPR_BENCHMARK_SEAMS=1 WHISPR_EVALUATION_ROUNDS=30 \
  WHISPR_BUILD_REVISION="$(git rev-parse HEAD)-dirty" \
  WHISPR_SWIFT_VERSION="$(swift --version)" \
  WHISPR_CLEANUP_RUNTIME='YOUR_ACTUAL_RUNTIME_TAG_REVISION_AND_VERSION' \
  swift test "${swift_flags[@]}" --filter AccuracyEvaluationTests
```

Set `WHISPR_CLEANUP_ENDPOINT` for another loopback service. Set the runtime label from
its actual installed pin; the bundled stack digest alone does not identify an upgraded
service. No service is installed, replaced or restarted by this evaluation.

`.build/accuracy-cleanup.json` contains numeric observations and reference IDs for full
cleanup, the previous word-only reuse and the current seam checks, in rotating order.
It reports exact/reference-word mismatches, changes relative to full cleanup, the loss
of reuse, and p50/p95 request latency. `.build/accuracy-synthetic-review.json` contains
only public synthetic inputs, references and model replies for manual adjudication.
`.build/seam-decision-cost.json` measures the decision overhead separately. These are
sequential synthetic service measurements, with shared prompt caching; they do not
measure microphone latency, contention at release, energy or visible text.

Review lost/added words, changed numbers or names and incorrectly resolved corrections
separately from punctuation, capitalisation, hyphenation and valid number formatting.
The word metric alone cannot make that distinction. A correction-cue veto is deliberately
conservative and incomplete: arbitrary backwards references and unfamiliar languages can
still cross an early seam. Safe reuse on synthetic cases does not establish real-speech
accuracy.

## Optional consented speech

Keep real audio, transcripts, manifests and review notes outside the checkout. Create a
local JSON manifest in the audio directory, with `schema: 1`, `consent: true`, a nonempty
`provenance` describing consent, recording date, microphone, noise and capture conditions,
and `cases` containing `wav`, `reference` (what was actually spoken, including corrections)
and `expected` (an array of acceptable cleaned outputs). WAVs must be mono 16 kHz and no
longer than 120 seconds. Paths resolve within the manifest directory. Use representative
cold starts, microphones, noise, dictation lengths and early-chunk boundaries.

Set `WHISPR_EVALUATE=1`, `WHISPR_SPEECH_MANIFEST=/absolute/private/path/manifest.json`
and `WHISPR_ASR_MODEL=ultra` with the same test command. The ASR cache must already exist;
downloads are disabled. Set `WHISPR_ASR_CACHE_ROOT` if the cache is in a custom model
folder, such as `~/Library/Application Support/WhisprLite/Models`.
`.build/accuracy-speech.json` records case indices, raw ASR word
errors and reference word counts separately from cleanup errors/review flags and coverage
uncertainty. It stores no audio, transcript, private filenames or provenance. Review
semantic cleanup errors locally against the original audio. Offline files do not validate
physical microphone startup or capture loss.

## Physical release-to-visible baseline

Collect at least 30 observations on the current built app, across representative destination
apps and cold/warm conditions. Observe the physical key release and the first frame showing
the complete intended result using timestamped video, or an accessibility observer with
the same clock. Paste dispatch is insufficient. Do not use a human reaction click as the
visible-text timestamp. Keep videos and private content outside the checkout.

Enable debug logging to obtain capture, ASR and cleanup stage timings, then join those
with the observed release/visible times by trial. Record failures and missing first words
alongside successful trials; do not discard them to improve the latency distribution.
For cold on-demand starts, check initial words immediately after the press and after a
long idle, record start-to-first-packet timing and count gaps. Exercise built-in, USB and
Bluetooth microphones. Review coverage warnings on speech and noise; RMS is evidence of
possible missing words rather than proof.

Create a JSON file with `schema: 1` and these metadata strings: `build`, `chip`, `macos`,
`asr_model`, `asr_runtime`, `cleanup_model`, `cleanup_runtime`, `capture_mode`
(`on-demand` or `warm`) and `observation_method` (`video` or `accessibility-observer`).
Its `observations` array needs at least 30 entries, each with `destination`,
`destination_version`, `condition` (`cold` or `warm`) and nonnegative millisecond values
for `release_to_visible_ms`, `capture_ms`, `asr_ms`, `cleanup_ms`, `insertion_ms`.
Here `insertion_ms` ends at visible text; record each stage's actual duration without
forcing their sum to equal end-to-end time. Do not include transcript text.

```sh
python3 scripts/summarize-latency.py /private/path/observations.json
```

The report groups stage and visible latency by destination/version and cold/warm condition,
using p50 and nearest-rank p95. The tool validates observations; it does not acquire them.
There is currently no physical baseline for this change. Physical first-word checks and
real-speech warning thresholds also remain open.

## Short-dictation speculation decision

Keep batch ASR plus the existing hold warm-up. Do not enable a short snapshot in normal
capture yet. The earlier 30-pair overlap experiment increased final-request latency from
94 ms median / 111 ms p95 to 173 ms / 182 ms; projected wins needed a pause long enough
for an exact final-matching snapshot. That experiment is historical evidence, not a
current physical baseline (see local `CHECKS.md`, “Speculative full cleanup”).

Revisit only after the current physical and reviewed speech baselines exist. The prototype
must use one pause snapshot per recording, serialize ASR with warm-up/final decoding,
settle cleanup server work even after cancellation, reuse only completed cleanup with
an exact final ASR/settings match, and insert once after release. Compare interleaved
baseline/prototype trials, including release during each speculative stage. Require
accuracy parity and improvements in typical and tail latency after accounting for reuse,
wasted work and energy. The current change adds no speculative ASR/cleanup workload.

## 31 October 2026 measurements

Machine: Apple M1 Max (8P + 2E), 64 GB, macOS 27.0.1 (26A434), Swift 6.4.
Cleanup: default Gemma model and built-in prompt, installed llama.cpp `b11819`, revision
`0693dbfb915f33233818373b5f6969396658d02c` / `0.7.0-dev`. The listening executable's
path was checked against that runtime. ASR: ParakeetCore 0.3.0, cached Ultra model.
No model download, microphone capture or private text was used.

The 37-case comparison ran 30 rotating-order rounds (1,110 observations per condition).
Current seam outputs matched full cleanup in all observations. Both English cross-seam
corrections passed; the previous reuse kept the replaced words. Reuse remained available
for both independent cases and was rejected in four questionable cases. Those deliberately
selected cases do not estimate the frequency of fallback in ordinary speech.

A three-round follow-up used the same timeout wrapper for both reuse paths:

| Sequential service path | Observations | p50 | p95 |
| --- | ---: | ---: | ---: |
| Previous word-only reuse | 111 | 97.44 ms | 252.24 ms |
| Current seam checks | 111 | 97.85 ms | 254.52 ms |
| Full cleanup | 111 | 121.40 ms | 282.76 ms |

The single tail-correction case cost about 22 ms median relative to unsafe reuse in both
runs; the two-chunk correction was roughly even. The decision to retain the seam protection
prioritises preserving the correction. Shared prompt caching and condition order strongly
affect these figures; do not claim a general speed improvement or extrapolate to physical
release-to-visible latency. Decision-only checks over all 13 versioned cases took about
0.20 ms median / 0.37 ms p95 in a debug build (1,000 iterations).

Agent review found remaining full-cleanup failures: the number correction and German
correction were retained, `Whispr Lite` became `Whisper Lite`, a realistic retro-date
correction retained the replaced day, and a spoken new line was lost. Other mismatches
included potentially valid discourse words, capitalisation and punctuation. Exact-match
or word-error rates alone would misclassify those; references have not been changed to
match the model. These failures require further prompt/model work and human adjudication.

Three additional public WAVs generated with macOS `say`, Samantha, 180 words/minute,
lasted 1.24, 2.78 and 20.71 seconds. Raw Ultra ASR had 0 errors over 65 reference words,
and none triggered a coverage warning. Two cleanup outputs differed from the correction
references (3 and 8 word errors) and require review. This
small synthetic smoke check does not validate natural speech, hardware startup, missing-
speech recall or warning false-positive rates. The physical and consented speech gates
above remain open. Short-dictation speculation remains deferred.

Metric reports and synthetic review replies are local under `.build/`; the 30-round
reports were retained with `-30-rounds` filenames. They are deliberately not committed.
