# Validation status — 21 October 2026

## Done, with evidence

**Apple build (GitHub Actions, `macos-26`, Xcode 26.6 / iOS 26.5 SDK, MLX Swift 0.32.3)**
- `xcodebuild archive` of the iPhone app (Release, arm64, signing disabled) succeeds with no errors.
- `xcodebuild test` on an iOS 26.5 iPhone simulator: 6 of 6 XCTest cases pass.
  - The scheduler and seeded-noise tests compare against reference fixtures.
  - The official-tokenizer test runs on the real 20 MB `tokenizer.json`.
  - The remaining tests cover preset/size validation, manifest safety and file integrity.
- `Moss-unsigned.ipa` contains `Payload/Moss.app` with:
  - the arm64 Mach-O executable;
  - `mlx-swift_Cmlx.bundle/default.metallib` (the MLX Metal shaders);
  - `Assets.car` and the app icons;
  - `model-manifest.json`, `PrivacyInfo.xcprivacy` and `Info.plist` (MinimumOSVersion 26.0, iPhone).

**Real-weight inference on Apple silicon (not an iPhone)**
- The `MossCLI` macOS harness compiles the app's own `Moss/Engine/*.swift` and `Moss/Models.swift` unchanged. It downloaded the pinned 12.1 GB of weights, verified their SHA-256 and ran the full pipeline on the GPU.
- Machine: GitHub `macos-26` runner, Apple M1 (Virtual), 7 GB RAM, paravirtualised GPU, macOS 26.6.2.

| Run | Settings | Result | Time | Peak process footprint |
|---|---|---|---|---|
| `Validation/mac-best-512.png` | 512×512, Best (50 steps, CFG 3, shift 5, layer 22 skipped in negative), seed 42, "A red fox sitting in fresh snow, golden hour, photograph" | Correct, detailed image | 1,589 s (~29 s/step) | 1.62 GiB (sampled); 1.74 GB (`time -l`) |
| `Validation/mac-fast-1024.png` | 1024×1024, Fast (8-step DMD adapter, CFG 1, shift 5), seed 7 | Correct, detailed image | 589 s (~61 s/step) | 2.70 GiB (sampled); 2.90 GB (`time -l`) |

Logs are in `Validation/*.log`. On this VM the time is dominated by system time (storage reads), not GPU compute.

**Checkpoint layout** (`Validation/checkpoint-headers.txt`, read from the downloaded files)
- Transformer: 8-bit g64 U32 weights, BF16 scales and modulation/embedding layers, 42 layers.
- Text encoder: 6-bit g64, 32 layers, partial rotary 0.25, rope θ 1e7, F32 folded norms.
- Decoder: F32 throughout, 32 groups, BN eps 1e-4.
- Tokenizer: NFC normaliser, Split(Isolated)+ByteLevel pre-tokeniser, `ignore_merges` false.
- These match the engine's hard-coded assumptions, which are also asserted at load time.

**Code review against references** (`felix-ab/moss-image-mlx`, official ComfyUI `model.py`, `mlx-lm` qwen3_5/gated_delta)
- The transformer, sampler, text encoder, decoder and DMD adapter maths match.
- Fixes made:
  - The transformer streamed every layer twice per guided step. It now streams once per step for both branches, which halves storage reads.
  - The text encoder now encodes both prompts per layer load.
  - The tokenizer now keeps text between regex matches and rejects unknown pre-tokeniser formats.
  - Layout assertions were added.
  - Launch-time re-hashing of all 12 GB was replaced by one hash after download plus a size/date check.
  - Generation is no longer cancelled by brief interruptions such as Control Center or notifications (only real backgrounding stops it).

## Not done
- **No run on a physical iPhone.** iPhone speed, iOS memory limits (jetsam), thermal behaviour, downloads, Files folders, Photos export, VoiceOver and Dynamic Type are untested. iOS counts memory differently from macOS, so the footprints above are indications only.
- **No pixel-level parity check against the official PyTorch pipeline.** Images are judged visually. The sampler schedule and noise were checked numerically against torch.
- **Signulous signing has not been tried.** Neither has whether its profile carries the increased-memory or extended-addressing entitlements; the app does not rely on them.
