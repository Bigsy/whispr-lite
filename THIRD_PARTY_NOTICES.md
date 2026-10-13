# Third-party notices

## MediaRemote Adapter

Vendored from [ungive/mediaremote-adapter v0.7.6](https://github.com/ungive/mediaremote-adapter/tree/v0.7.6),
commit `3ac3d4bdf862c7b5399b4fba4df5689f5c38609a`.
Copyright (c) 2025 Jonas van den Berg. BSD-3-Clause; the complete license is retained
in [Vendor/mediaremote-adapter/LICENSE](Vendor/mediaremote-adapter/LICENSE) and copied
into the app bundle. Original source files are unchanged. Local additions live only in
`Vendor/mediaremote-adapter/patches/`; see its README. The app does not link this framework:
the bundled framework is dynamically loaded by the system Perl host.
The bundled broker framework compiles only the upstream globals, MediaRemote wrapper and
utility helpers it uses. The full upstream adapter is built separately for local benchmarks.

## Behavioral reference

OpenWhispr v1.10.2, commit `1c123e8739f87c0a72d0b252bc9cff14e684b7f4`, is the planning
reference for hold-to-talk, paste layout lookup and clipboard restoration. No OpenWhispr
source code is vendored. The Carbon keyboard-layout search in this implementation is
written against the macOS APIs.

The recording pill also follows the focus-preserving behavior of that revision's
`src/components/dictation/VoicePill.tsx` and `src/helpers/windowConfig.js`: compact
recording/processing feedback and a nonactivating floating window. The reference's
MIT license was checked. The native AppKit/SwiftUI indicator is implemented here;
no React/Electron source, assets or animation/waveform machinery is copied.

The private exporter separately checks the installed OpenWhispr 1.8.3 prompt resolution
and request format. Its exported prompt/dictionary stay in ignored private files and
the user's private application-support directory; they are not app-bundled assets.
Public source-file hashes are recorded in `stack.lock.json`. No Electron runtime is used.

Installed OpenWhispr 1.8.3's public `src/helpers/clipboard.js` and `mediaPlayer.js` were
also inspected for generic macOS paste and explicit media pause/play behavior. Its
package declares MIT licensing; the inspected file hashes are retained in the inventory.
The native paste, bounded diagnostics and audio-level wave are independently implemented.

Media behavior was also checked directly on GitHub against the current released v1.10.2
(`1c123e8739f87c0a72d0b252bc9cff14e684b7f4`) and main
(`5f9a88b0481a066c147bfd2c38ea1d9acae502ee`). Their `mediaPlayer.js` files have the same
SHA-256, `0d803970e16772815147c82c1cafb0fbc50fc887441c6377fbdc4077b4a3107b`:
macOS uses explicit Pause/Play with a remembered pause flag and a media-key fallback;
it does not validate track identifiers. The MIT license was checked. No source is copied
from these files; our content comparison and persistent broker are local additions.

Generic paste was rechecked against that v1.10.2 release's `src/helpers/clipboard.js`
(SHA-256 `5770b0aeb65f951e522a754f77692faf3922d7d9c995ea874bb62cf3dabcdbbb`)
and `resources/macos-fast-paste.swift`
(SHA-256 `d41fa8582d9bf69a1a5d70bfc181cf5460df1f3e15afe61efeb47eec8ebd348d`).
Its native helper posts Command-V down/up at the session event tap. Our implementation
uses that posting level with an independent private event source, physical-modifier
guard and keyboard-layout lookup. No source or arbitrary paste delays are copied.

## Cleanup runtime and models

The separately installed llama.cpp b11564 runtime (MIT) and Gemma 4 E2B QAT/MTP weights
are not bundled with the app. `Resources/cleanup-stack.json` records the tested binary,
release archive, runtime files and model hashes. Setup downloads the official
[b11564 macOS ARM64 release](https://github.com/ggml-org/llama.cpp/releases/tag/b11564),
commit `08ffba21e5c2f1728b6b405c05ff3913f65706d4`, retaining its MIT LICENSE alongside
the standalone binaries under the owned cleanup directory. Model files come from the pinned revision of
[unsloth/gemma-4-E2B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF);
the upstream model terms apply to these separately downloaded assets.

## ParakeetCore

[Bigsy/parakeet-ane-server v0.3.0](https://github.com/Bigsy/parakeet-ane-server/tree/v0.3.0),
commit `81e9b2f9d850b3a4dfced84b3e1325ed7075dcd7`, is the app's exact SwiftPM dependency.
Its MIT license and notices are copied into app bundles. FluidAudio's Apache-2.0 license
and third-party notices are also bundled. FluidAudio is pinned by that package to 0.17.7
(`503b4bd1bbf7220882de39fe8ae6716aae4132da`). Models are separately cached assets.

The optional Ultra cache comes from
[FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml),
based on [Moondream Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra)
and NVIDIA Parakeet TDT v3. Its model card declares CC-BY-4.0. The model card is retained
with the separate cache; the bundled ParakeetCore notices also attribute these models.
