# Historical stack and benchmark notes

Preserved from the README before its cleanup on 10 October 2026. These are the original
OpenWhispr experiments and machine notes, primarily from 9 October. Versions, paths,
ports, commands and references to “today” or “now” below describe that historical setup.
The reported timings are not measurements or promises for the current Whispr Lite app.

For the current app, see [README.md](../README.md). Current setup and tuning are in
[DEVELOPMENT.md](../DEVELOPMENT.md); measured app checks are in [CHECKS.md](../CHECKS.md).

## Where things stand

From releasing the key to text appearing, OpenWhispr's own debug log over five real
dictations (1.6-11.2 s of audio):

| Stage | Time | Notes |
|---|---:|---|
| Transcription | 126-203 ms | parakeet-ane-server, +4-13 ms OpenWhispr overhead |
| Cleanup LLM | 148-378 ms | llama.cpp, +13-31 ms OpenWhispr overhead |
| Paste | 325-380 ms | OpenWhispr's paste path, see below |
| **Total** | **630-890 ms** | |

That morning, before any of this, the same pipeline (OpenWhispr's built-in Parakeet plus
Ollama) took ~170-530 ms to transcribe and ~370 ms to clean up, and 1.5-1.7 s after a long
idle.

## Target

| | Release to text |
|---|---:|
| Today (OpenWhispr + both servers) | 630-890 ms |
| Phase 1: own client, batch | ~300-550 ms |
| Phase 2: own client, streaming | ~200-300 ms long dictations, ~200 ms short |


## Decisions and findings

### Cleanup LLM: Ollama to llama.cpp + MTP

Benchmarked with 24 synthetic dictations sent exactly as OpenWhispr sends them (its
cleanup prompt and custom dictionary, thinking disabled), warm:

| Engine / config | Median | p90 |
|---|---:|---:|
| Ollama 0.40.2 (bundled llama.cpp 0.5.0-dev) | 372 ms | 551 ms |
| llama.cpp 0.6.0, same GGUF, no tuning | 381 ms | 584 ms |
| + Gemma MTP drafter (`--spec-type draft-mtp`) | 253 ms | 353 ms |
| + `--swa-full` | 248 ms | 353 ms |
| n-gram drafting (various), alone or with MTP | 267-297 ms | |
| Ollama + the same drafter (`DRAFT` in a Modelfile) | 392 ms | 558 ms |
| mlx-lm, text-only 4-bit | 331 ms | 524 ms |
| mlx-vlm QAT 4-bit + MTP | 423 ms | 534 ms |
| Installed service (morning) | 237 ms | 357 ms |
| + unsloth's QAT MTP drafter, drafts up to 6 tokens | 233 ms | 328 ms |
| **Installed service (evening)** | **227 ms** | **332 ms** |

- Ollama already runs llama.cpp's server internally, so it adds almost nothing. The win
  is the MTP drafter: generation went from ~112 to ~185 tok/s at 82% acceptance, and the
  output matched Ollama's 48/48.
- Ollama loads the drafter but its bundled llama.cpp gets no speedup from it (confirmed by
  running each binary with the other's flags). A future Ollama release may fix that.
- `--swa-full` cuts prompt processing from 79 to 64 ms by skipping sliding-window
  checkpoints. With it on, longer drafts pay off: interleaved runs gave a mean of 259 ms
  at the default draft length of 3, 237 ms at 5, 226 ms at 6 and 263 ms at 8. (A morning
  sweep without `--swa-full` showed 3-6 alike.)
- MLX was rejected: its 4-bit builds changed outputs in about half the cases, and the MLX
  path with MTP re-processes the system prompt every request and loads the vision and
  audio towers.
- Benchmarked model: unsloth's Gemma 4 E2B QAT "smart Q4_0" from August (2,620,370,976
  bytes, sha256 `a48ad414...4ebc`), text only, with ggml-org's generic
  `mtp-gemma-4-E2B-it-Q4_0.gguf` drafter (59 MB, sha256 `718d3a44...45ef4`).
- **Now on unsloth's current files** from
  [unsloth/gemma-4-E2B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF):
  `gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` (sha256 `e5310072...16889`) and
  `mtp-gemma-4-E2B-it.gguf` (sha256 `586f2460...4aae0`). Despite the new name and hash,
  the model is tensor-for-tensor identical to the August file; only the order of the
  header fields changed. The drafter has different weights: it's accepted more often
  than ggml-org's (84% vs 82% at length 3, 74% vs 68% at 6) with a better p90, though
  the same mean. Output stayed byte-identical in every configuration.

Ollama's logs showed the first dictation after 5+ minutes idle taking 1.5-1.7 s. llama.cpp's
Metal residency timeout (180 s) accounts for only ~30 ms of that. The rest is most likely
macOS paging the weights out under memory pressure (8 GB of swap in use). The service now
pins weights with `--load-mode mmap+mlock` and keeps Metal buffers resident for 24 h; that
fix is not yet verified under real memory pressure.

### Speech-to-text: OpenWhispr's sherpa-onnx to the Neural Engine

| Option | 8 s | 25 s | Notes |
|---|---:|---:|---|
| OpenWhispr built-in (sherpa-onnx, CPU) | ~170 ms | ~530 ms | 2.2 GB footprint, mostly swapped out; ~500 ms cold |
| parakeet-mlx (GPU) | ~165 ms | ~295 ms | 3.3 GB peak |
| **parakeet-ane-server (ANE)** | **~70 ms** | **~175 ms** | includes WebM decode |

[dokterbob/macos-speech-server](https://github.com/dokterbob/macos-speech-server) was
evaluated and not used: it splits audio on VAD pauses and transcribes each piece without
context (its own open PR #36 documents dropped ~2 s phrases), and it pins an old
FluidAudio without the Unified model. Details, the decode work, and the idle measurements
are in parakeet-ane-server's README.

### OpenWhispr's overhead

- **Paste is the biggest single stage.** `pasteMs` runs from the start of the paste until
  OpenWhispr's ⌘V helper exits. It includes a hard-coded 120 ms wait before ⌘V on macOS
  (`PASTE_DELAYS.darwin`; its own streaming mode uses 15 ms), saving the current clipboard,
  and spawning `macos-fast-paste`, which posts ⌘V, sleeps 8 ms, releases, and sleeps 20 ms.
  The 450 ms clipboard restore (`RESTORE_DELAYS.darwin`) runs in the background and is
  not included. The text lands ~30 ms before the timer stops, so ~300-350 ms of it is real.
- **Per-call overhead is small.** OpenWhispr's transcription and cleanup timings match the
  servers' own logs within 4-31 ms. Merging the two calls into one endpoint would save
  about that much, so it isn't worth doing on its own.
- **Memory:** OpenWhispr runs 11 processes with ~850 MB physical footprint, even with
  its local Parakeet switched off.
- **Licence:** MIT, so its paste and hotkey code can be borrowed with attribution.

### Why build a client instead of patching OpenWhispr

- Pasting in-process removes ~300 ms that OpenWhispr's design can't avoid.
- Streaming needs the client to send audio while the key is held. OpenWhispr's
  self-hosted mode uploads only after release. Upstream:
  - [PR #1385](https://github.com/OpenWhispr/openwhispr/pull/1385) would let dictation
    stream to a custom server over the OpenAI Realtime WebSocket. Open since July, no
    review.
  - In [#1280](https://github.com/OpenWhispr/openwhispr/issues/1280) a maintainer called
    custom realtime endpoints "a deliberate omission rather than an oversight" (for Note
    Recording). A proposal for an explicit OpenAI-compatible realtime provider (5 Oct) is
    unanswered.
- I use none of OpenWhispr's other features (notes, meetings, agents, cloud).

### Streaming model: Parakeet Unified, not Nemotron

FluidAudio's LibriSpeech test-clean figures (aggregate WER, lower is better):

| Model | WER | Streaming behaviour |
|---|---:|---|
| Unified, batch (today) | 1.68% | n/a |
| **Unified, streaming** | **1.79%** | commits ~2 s behind speech; re-encodes a 7.68 s window per chunk |
| Nemotron Speech Streaming, 560 ms chunks | 2.71% | commits ~0.6 s behind; cache-aware, never redoes work |
| Nemotron, 1120 ms / 2240 ms | 2.58% / 2.64% | |

Nemotron makes ~45% more errors for maybe 50-100 ms less work at key release. Start with
Unified streaming, keep the model switchable, and compare on real dictations. To compare
without anyone reading the text, run OpenWhispr's locally stored recordings through each
model and report only word-level disagreement against Unified batch.

### Things that didn't help

- **Keeping the speech model warm** with a 1 s silent transcription every 30 s while idle:
  no change to the ~50 ms first-request penalty after ~90 s idle, which comes from macOS
  clocking the CPU and Neural Engine down within seconds.
- **A combined batch endpoint** (see above): saves 20-40 ms at most.
- **Smaller llama.cpp micro-batches** (`-ub 128`): within noise.


## Tuned configuration

What the two servers run today, as LaunchAgents. Phase 0 turns these into files in this
repo.

### Cleanup LLM (`com.hedworth.llama-cleanup`)

```sh
GGML_METAL_RESIDENCY_KEEP_ALIVE_S=86400 \
/opt/homebrew/bin/llama-server \
  -m ~/models/gemma4-e2b-cleanup/unsloth-gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf \
  --spec-type draft-mtp \
  -md ~/models/gemma4-e2b-cleanup/unsloth-mtp-gemma-4-E2B-it.gguf \
  --spec-draft-n-max 6 \
  --swa-full -c 4096 -np 1 -fa on \
  --load-mode mmap+mlock \
  --reasoning off --temp 0 \
  --alias gemma4-e2b-cleanup:latest \
  --host 127.0.0.1 --port 11434 --no-webui
```

| Setting | Why | Measured |
|---|---|---|
| `--spec-type draft-mtp` + unsloth's QAT drafter | Gemma 4's multi-token-prediction head drafts tokens the main model verifies in one pass; output is unchanged | Median 372 → ~255 ms vs Ollama at draft length 3; 84% acceptance vs ggml-org's 82% |
| `--spec-draft-n-max 6` | Longer drafts pay off once `--swa-full` is on | Mean 259 ms at 3, 237 at 5, **226 at 6**, 263 at 8 |
| `--swa-full` | Full sliding-window cache, so prompts aren't processed in two passes around a checkpoint | Prompt processing 79 → 64 ms |
| `-c 4096 -np 1` | One user; the cleanup prompt plus a dictation is ~700-1000 tokens | |
| `--load-mode mmap+mlock` | Pin weights so macOS can't page them out between dictations | Targets the 1.5-1.7 s first request after a long idle; unverified under real memory pressure |
| `GGML_METAL_RESIDENCY_KEEP_ALIVE_S=86400` | Keep Metal buffers resident for 24 h (default 180 s) | Residency alone was worth only ~30 ms |
| `--reasoning off --temp 0` | No thinking and deterministic output, even if a client forgets to ask | |
| `--alias`, port 11434 | Same model name and port as the Ollama setup it replaced, so OpenWhispr needed no changes | |

Left at defaults after testing: `-ub 512` (128 was within noise), f16 KV cache, no n-gram
drafting (267-297 ms alone or combined with MTP).

Memory: identical allocations to the pre-tuning config. 2,484 MiB model + 41 MiB drafter
(memory-mapped), 72 MiB KV cache, ~220 MiB compute buffers.

### Speech-to-text (`com.hedworth.parakeet-ane`)

```sh
~/.local/bin/parakeet-ane-server --model unified --port 11435 --ffmpeg /opt/homebrew/bin/ffmpeg
```

Built and installed with `make install` from
[parakeet-ane-server](https://github.com/Bigsy/parakeet-ane-server); its README covers
its tuning (in-process WebM/Opus decode, sample-exact trims, single-pass resampling).

## Machine state (9 Oct 2026)

| | |
|---|---|
| Speech-to-text | `com.hedworth.parakeet-ane` on 127.0.0.1:11435, binary in `~/.local/bin` |
| Cleanup LLM | `com.hedworth.llama-cleanup` on 127.0.0.1:11434, `/opt/homebrew/bin/llama-server`, unsloth QAT model + drafter, `--spec-draft-n-max 6` |
| Models | `~/models/gemma4-e2b-cleanup/unsloth-*` (model + drafter); Parakeet CoreML in `~/Library/Application Support/FluidAudio/Models` |
| OpenWhispr | Transcription: Self-hosted, OpenAI-compatible, `http://127.0.0.1:11435/v1`. Cleanup: `http://127.0.0.1:11434/v1`. Debug logging on. |
| Ollama | Installed, login agent disabled (`launchctl disable gui/<uid>/com.ollama.ollama`) |
| Hardware | MacBook Pro, M4 Pro (8P + 4E), 24 GB, macOS 26.7 |

## Open questions

- The first transcription after ~23 min idle took 267 ms (vs ~110 ms warm), more than the
  90 s idle penalty. Is the Neural Engine model being evicted?
- WebM decode on real OpenWhispr recordings takes 11-56 ms vs 7-23 ms on the test clips.
  Moot once the client sends PCM.
- Parakeet Ultra vs Unified on real dictations.
- Does `mmap+mlock` hold the cleanup model's long-idle latency under real memory pressure?
