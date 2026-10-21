# Moss iOS

An experimental native SwiftUI iPhone app implementing on-device MOSS-Image-Base inference with MLX Swift. **This source has not been compiled with Xcode or tested on a physical iPhone in the authoring environment. It is not a verified working IPA.** The included GitHub workflow performs Apple compilation and reference tests before producing an unsigned IPA. A physical-device image test remains necessary afterward.

For the nontechnical installation guide, open **START-HERE.html** in the delivered package. No source editing or Mac is required for that route. See **INSTALL-ON-IPHONE.txt** after the build.

## Included

- Swift implementation of Qwen3.5 text encoding, byte-level BPE, 42-layer MOSS transformer, the snapped flow-matching Euler schedule, CFG and negative layer-22 skip, CPU float32 seeded noise, and the FLUX.2 small FP32 decoder.
- Layer-by-layer weight loading. Only embedding rows used by the prompt are read. The text encoder finishes before transformer loading; transformer layers finish before decoder loading. Intermediate embeddings and latents remain, not the earlier component's weights.
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

There is no trustworthy seconds-per-image measurement on this phone. Streaming the transformer requires approximately 549 GB of logical tensor reads for 50 steps with CFG, or about 53 GB for 8 steps with its adapter and no CFG. Storage caches can alter physical reads. Compute, thermal state, prompt length, and storage speed also matter. Expect a potentially long wait; the app estimates remaining sampling time after the first complete step. It does not show invented timings or a fake intermediate image.

## Memory limits

The default is 512 × 512. Try 768 only after a successful smaller generation. 1024 × 1024 is experimental. The UI accepts multiples of 16, dimensions from 256 to 1536 and a maximum of 1,048,576 total pixels. Long prompts are rejected above 1,024 tokens for phone memory, rather than silently truncated. The tokenizer supports the model's 4,096-token format, but the phone guard is intentionally tighter. Prompt text is stored unchanged; official chat-template formatting trims outer whitespace and uses NFC tokenization.

Weight sizes alone do not predict peak RAM. The transformer has about 439 MB of shared/refiner weights plus roughly 120 MB per streamed block; the adapter adds about 28 MB per block. Text encoder blocks are streamed and its 826 MB vocabulary table is never loaded wholesale. The decoder has about 112 MB of weights but its full-resolution FP32 activations can be much larger. Planning budgets are roughly 1–2 GB for short-prompt encoding, 2–4 GB for sampling, and 1–3 GB for 512–1024 decoding, including temporary arrays. **These are unmeasured planning ranges, not confirmed peaks or guaranteed limits.** File buffers, lazy graphs and Metal allocations may raise them.

The app requests increased-memory-limit and extended-virtual-addressing entitlements. An unsigned build cannot grant either permission. Signulous must have a compatible profile and preserve them when signing. Without them, smaller streamed runs might fit the normal allowance, but successful generation is not guaranteed. iOS jetsam or a fatal GPU runtime error can terminate the process before Swift can show an error. Moss records an unfinished-run flag and explains that interruption at the next launch.

## Reliability boundaries

- The app stops new work when interrupted or sent away from the screen. It does not promise background GPU generation or mid-image resume.
- Background URLSession handles downloads while iOS allows it. Force-quitting the app can stop background transfers until the app is reopened. Pause/resume is per file; integrity verification must finish before generation.
- Bookmarks persist access, but iOS or the Files provider can revoke it. External folders must remain locally available for offline use.
- Import copies files. Moving also copies and verifies before deleting the originals; this needs temporary free space. Existing destination files cause a safe failure.
- Checksum verification reads about 12 GB every launch. This is deliberately thorough and may take minutes.
- No analytics or app account. Default downloads contact Hugging Face. Photos and sharing act only when requested or enabled.

## Build

The canonical source configuration is `project.yml`. XcodeGen creates `Moss.xcodeproj` on GitHub. The workflow pins MLX Swift 0.32.3, selects Xcode 26.6 on macos-26, runs simulator tests, archives an unsigned arm64 iPhone app and checks for its Metal shader library before packaging. Source uploads can be ordinary repository files or `Moss-iOS-Source.zip` at the repository root.

No Apple signing credential, Hugging Face token, or model weight is needed for compilation. Unit-test preparation downloads only the approximately 20 MB tokenizer. Model weights download within the installed app.

## Validation

See `VALIDATION.md` for checks actually performed and those still outstanding. Successful syntax parsing is not Apple type checking. The build workflow has not been run by the author; it is supplied for the user's repository. There is no prebuilt IPA in this package.

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
