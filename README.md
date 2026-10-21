# Moss iOS

An experimental native SwiftUI iPhone app implementing on-device MOSS-Image-Base inference with MLX Swift.

**Status (21 October 2026):** the app compiles with Xcode 26.6 (iOS 26.5 SDK) on GitHub's macOS 26 runners, its unit tests pass on an iPhone simulator, and the unsigned IPA is produced by `.github/workflows/build.yml`. The app's engine sources, run on Apple silicon (a GitHub macOS runner) through the `MossCLI` harness with the real downloaded weights, produce correct images. It has **not** yet been run on a physical iPhone; see `VALIDATION.md`.

See **INSTALL-ON-IPHONE.txt** for installation with Signulous.

## Included

- Swift implementation of Qwen3.5 text encoding, byte-level BPE, 42-layer MOSS transformer, the snapped flow-matching Euler schedule, CFG and negative layer-22 skip, CPU float32 seeded noise, and the FLUX.2 small FP32 decoder.
- Layer-by-layer weight loading. Only embedding rows used by the prompt are read. Each text-encoder layer is read once and applied to both the prompt and the negative prompt; each transformer block is read once per sampling step and applied to both guidance branches. The non-layer transformer weights (~0.44 GB), text-embedder output and RoPE tables are computed once per image.
- Existing pinned MLX weights, verified with SHA-256; background downloads with resume data, folder selection/bookmarks, import, movement and deletion.
- Native prompt and JSON-layout input, negative prompt, aspect ratios, custom dimensions, presets, seed and advanced settings, sequential batches, cancellation, thermal throttling and interruption recovery messages.
- Persistent PNG gallery with embedded JSON metadata, favorites, settings reuse, zoom, Photos export, copying, sharing and bulk actions.
- Original SVG and opaque 1024-pixel light/dark/tinted icon assets.
- XcodeGen configuration, GitHub macOS build workflow, XCTest reference/integrity tests, browser upload guide, and an optional one-click Colab mirror notebook.

## Model choices

| Component | Pinned export | Download size |
|---|---|---:|
| Image transformer | VisualInference/MOSS-Image-Base-MLX-8bit | 5.493 GB |
| Text encoder | VisualInference/MOSS-Image-SFT-MLX-compact, 6-bit | 6.450 GB |
| Decoder | FP32 decoder-only export | 0.112 GB |
| Tokenizer/configuration | Pinned alongside the weights | 0.020 GB |
| Optional Fast adapter | lodestones/MOSS-Image-Base-8-steps-dmd, unmerged FP32 | 1.189 GB |

Exact mandatory download: **12,075,713,035 bytes**. Optional adapter: **1,189,176,800 bytes**. Original Base and SFT text-encoder shard hashes were compared and match, which supports reusing the compact SFT export's text encoder with the Base transformer. This app does not swap in the SFT image transformer.

The existing export avoids a new conversion job. The optional notebook mirrors those precise files into the owner's public Hugging Face account. It does not pretend that a generic 4-bit conversion supplies a working iOS runtime.

## Quality and speed limits

Best uses 50 steps, guidance 3, shift 5, and negative-only layer-22 skip. Balanced uses 20 steps with the same guidance and shift. Fast uses the separate 8-step DMD adapter, guidance 1 and shift 5. Editing advanced settings overrides these values. Negative prompts are unused when guidance equals 1.

8-bit image weights and 6-bit text weights are approximations. No measured percentage of image-quality loss is available from this project. The distilled adapter with these quantized weights is experimental. Numerical and image parity with the full-precision PyTorch pipeline are not established.

There is no seconds-per-image measurement on an iPhone yet. On a GitHub macOS runner VM (3-core M1, paravirtualised GPU, 7 GB RAM) a 512 × 512 Best image took 26.5 minutes, about 29 s per step, mostly storage reads. Streaming the transformer reads about 5.05 GB of block weights per sampling step (about 253 GB for 50 steps, 101 GB for 20), or about 6.2 GB per step with the Fast adapter (about 50 GB for 8 steps). Storage caches can alter physical reads. Compute, thermal state, prompt length, and storage speed also matter. Expect a potentially long wait; the app estimates remaining sampling time after the first complete step. It does not show invented timings or a fake intermediate image.

## Memory limits

The default is 512 × 512. Try 768 only after a successful smaller generation. 1024 × 1024 is experimental. The UI accepts multiples of 16, dimensions from 256 to 1536 and a maximum of 1,048,576 total pixels. Long prompts are rejected above 1,024 tokens for phone memory, rather than silently truncated. The tokenizer supports the model's 4,096-token format, but the phone guard is intentionally tighter. Prompt text is stored unchanged; official chat-template formatting trims outer whitespace and uses NFC tokenization.

Weight sizes alone do not predict peak RAM. The transformer has about 439 MB of shared/refiner weights plus roughly 120 MB per streamed block; the adapter adds about 28 MB per block. Text encoder blocks are streamed and its 826 MB vocabulary table is never loaded wholesale. The decoder has about 112 MB of weights but its full-resolution FP32 activations can be much larger. Measured on the macOS harness: peak process footprint 1.62 GiB for a complete 512 × 512 Best image (see `VALIDATION.md` for other sizes). iOS memory accounting differs from macOS, so these are indications, not iPhone guarantees. File buffers, lazy graphs and Metal allocations may raise them.

The app requests increased-memory-limit and extended-virtual-addressing entitlements. An unsigned build cannot grant either permission. Signulous must have a compatible profile and preserve them when signing. Without them, smaller streamed runs might fit the normal allowance, but successful generation is not guaranteed. iOS jetsam or a fatal GPU runtime error can terminate the process before Swift can show an error. Moss records an unfinished-run flag and explains that interruption at the next launch.

## Reliability boundaries

- The app stops new work when interrupted or sent away from the screen. It does not promise background GPU generation or mid-image resume.
- Background URLSession handles downloads while iOS allows it. Force-quitting the app can stop background transfers until the app is reopened. Pause/resume is per file; integrity verification must finish before generation.
- Bookmarks persist access, but iOS or the Files provider can revoke it. External folders must remain locally available for offline use.
- Import copies files. Moving also copies and verifies before deleting the originals; this needs temporary free space. Existing destination files cause a safe failure.
- Every file is SHA-256 checked once after download or import. Later launches only confirm each file's size and modification date; Settings → Verify all files re-reads all 12 GB.
- No analytics or app account. Default downloads contact Hugging Face. Photos and sharing act only when requested or enabled.

## Build

The canonical source configuration is `project.yml`. XcodeGen creates `Moss.xcodeproj`. `.github/workflows/build.yml` pins MLX Swift 0.32.3, selects the newest Xcode 26 on `macos-26`, archives an unsigned arm64 iPhone app, runs the simulator tests, checks for the MLX Metal library and packages `Moss-unsigned.ipa`. `.github/workflows/inference.yml` (triggered by pushing `ci/inference.json` to the `run-inference` branch) builds the `MossCLI` macOS harness from the same `Moss/Engine` sources, downloads the pinned weights and generates an image.

No Apple signing credential, Hugging Face token, or model weight is needed for compilation.

## Validation

See `VALIDATION.md` for checks actually performed and those still outstanding.

## Sources and licensing

- [Official model and pipeline](https://huggingface.co/OpenMOSS-Team/MOSS-Image-Base)
- [Official code](https://github.com/OpenMOSS/MOSS-Image)
- [MLX reference port](https://github.com/felix-ab/moss-image-mlx)
- [MLX Swift 0.32.3](https://github.com/ml-explore/mlx-swift/tree/0.32.3)
- [8-step Space](https://huggingface.co/spaces/hugging-apps/moss-image-8-step-dmd-base)
- [8-step adapter](https://huggingface.co/lodestones/MOSS-Image-Base-8-steps-dmd)
- [GitHub runner toolchain](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)
- [Signulous signing dashboard](https://www.signulous.com/sign-apps)

Apache-2.0 for this project. Upstream licenses and notices are in `LICENSE`, `NOTICE` and `Licenses/`. Model weights are downloaded separately under their own applicable licenses. This is not an official OpenMOSS or Apple app.
