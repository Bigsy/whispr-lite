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

### 2. Unified streaming ASR

- [ ] After reviewing experiment 1, trial the existing real streaming adapter with paced
  input against batch; include short speech, corrections, pauses and long dictation.
- [ ] Measure residual finish and whole pipeline latency, disagreement, compute and
  fallback load time. Unified is streaming-capable; Ultra/v2/v3 are currently batch-only.
  The current streaming export has about 2.08 seconds of initial window latency.
- [ ] Review whether the gain merits the accuracy/resource tradeoff before app integration.
  Retain one authoritative final result and final-only insertion. Settle CoreML ownership
  before cancellation fallback or mode changes; never split dictation context at pauses.

### 3. Streaming partials into Gemma prefill

- [ ] After reviewing streaming, feed changed full transcript snapshots to prompt-only
  evaluation; measure incremental gain over streaming without prefill, including revisions.
- [ ] Prototype one cleanup slot, latest-snapshot coalescing and a 500 ms minimum interval.
  Use a fresh scheduler per recording; verify server settlement, not just client cancellation.
  Overlap ASR finish with prefill settlement, then issue final cleanup after both complete.
- [ ] Check output parity, cache reuse and contention before deciding on integration.
  Prefill moves input evaluation earlier; final output generation still takes time.

### 4. Lower-priority experiments, only after the above decisions

- [ ] Consider removing redundant template/tokenisation round trips (existing short-input
  measurements suggest roughly 7–8 ms), preserving exact context-limit rejection.
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
