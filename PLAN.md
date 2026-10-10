# Whispr Lite — remaining work

Updated: 10 October 2026. Implementation and setup belong in [DEVELOPMENT.md](DEVELOPMENT.md);
measured evidence belongs in [CHECKS.md](CHECKS.md). This plan tracks decisions and open work.

## Optimisation experiments — prototype, measure, decide

Build a small disposable benchmark first for each idea. Compare it with the existing
path, review the benefit and accuracy, then decide whether to integrate, revise or drop
it before starting the next experiment. Production wiring and extensive tests follow
an accepted result; they are not prerequisites for these prototypes.

Use synthetic dictation and keep private prompts/dictionaries in RAM. Retain raw metrics
only in ignored `bench/results/`. Preserve installed services, model caches and settings.
Record at least 30 observations per measured condition with median/p90/p95, interleaved
comparisons, output parity and clearly separated preparation/release costs. Never label
cleanup-only or ASR-only measurements as physical release-to-visible-text latency.

### 1. Fixed Gemma prompt prefill — accepted for preparation

- [x] Prototype exact prompt/dictionary prefix evaluation through the pinned server's
  `/completion` endpoint with `n_predict: 0`, then use the normal final chat request.
- [x] Check generation behaviour, exact template/token-prefix compatibility, actual
  final-request cache reuse, output parity and context budget with the saved settings.
  The pinned server samples one token at `n_predict: 0`; its output is discarded.
- [x] Compare baseline/prefill with an already warm prefix and a forced prompt-cache miss;
  report prefill time, work left after a simulated button release and total work.
  Model weights stay warm: cache-miss measurements do not establish cold-start/idle gains.
- [x] Accept preparation-time warming under the user's instruction to integrate a
  successful experiment. Warm-prefix benefit is negligible, so omit per-press prefill.
  Benchmark details and the integration's validation belong in CHECKS.md.
- [ ] Verify the first physical dictation after startup/settings/readiness recovery,
  including long idle and an independent cleanup-service restart. Automatic restart
  detection and button-press recovery are not part of this change.

### 2. Unified streaming ASR — rejected for common short dictation

- [x] After reviewing experiment 1, trial the existing real streaming adapter with paced
  input against batch. Decide on short speech, corrections and pauses under five seconds;
  the user says these cover about 99% of use. Treat long dictation as an edge case.
- [x] Measure residual finish, disagreement and fallback load time. The 30-run synthetic
  ASR trial was slower than batch after release for all three common clips. Whole-pipeline
  latency, compute and power remain unmeasured; no app integration is justified.
  Unified is streaming-capable; Ultra/v2/v3 are currently batch-only.
  The current streaming export has about 2.08 seconds of initial window latency.
- [x] Review the short-clip result before app integration. Keep batch as the real-model
  app path. The longer synthetic clip has a streaming/batch word disagreement and is
  secondary to the user's short-dictation workload.
  Retain one authoritative final result and final-only insertion. Settle CoreML ownership
  before cancellation fallback or mode changes; never split dictation context at pauses.

### 3. Streaming partials into Gemma prefill — rejected for common short dictation

- [x] Mock prompt-only evaluation from actual synthetic Unified partial snapshots against
  the already warm fixed prefix. The one-second clip emitted no partial; the correction
  and pause clips added only one and three reusable tokens respectively.
- [x] Compare 30 baseline/prefill cleanup pairs per eligible clip with isolated Gemma,
  output parity, cache reuse and lead time. Projected median saving is 2.0 and 1.5 ms.
  Do not wire a per-recording scheduler or contend with final cleanup for this result.
  A production scheduler, cancellation settlement and whole-pipeline timing would be
  necessary if a future streaming model produces earlier useful partials.

### 4. Lower-priority experiments

- [x] Mock removal of per-request template/tokenisation round trips. Thirty paired
  synthetic comparisons saved only 2–4 ms median for the user's short clips. Keep
  exact context-limit rejection and the current implementation.
- [ ] Consider one ASR warm-up on press after inactivity, safely settled before real ASR.
  Repeated `prepare()` is a no-op; periodic idle silence pings previously showed no benefit.
- [ ] Consider speculative full cleanup during pauses, reusing output only if the final
  transcript and settings match exactly. Measure wasted generation and single-slot contention.

## Existing release acceptance remains open

- [ ] Review/freeze cleanup expected outputs; validate real speech and the streaming long
  fixture disagreement. Synthetic repeatability alone does not establish accuracy.
- [ ] Validate physical hotkeys, onset/final words, devices, permissions, sleep/lock and
  indicator focus/accessibility across Spaces, full-screen windows and multiple displays.
- [ ] Complete destination, keyboard-layout, modifier and clipboard-ownership checks;
  verify actual visible text rather than merely successful Command-V dispatch.
- [ ] Complete Music/Spotify/browser playback recovery and observed pause/resume timings,
  including user playback changes, helper failure and cancellation.
- [ ] Measure real release-to-visible-text by stage with 30+ warm samples per condition;
  separate 90-second/5-minute/25-minute idle, memory pressure, footprint and power trials.
- [ ] Finish first-use model provisioning, notarisation, another-Mac installation and
  daily-use acceptance with rollback. Retire OpenWhispr only through explicit migration.
