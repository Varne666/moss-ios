# Validation status — 21 October 2026

This is a complete source implementation supplied for an experimental port. It is **not a verified working iPhone app**, and no prebuilt IPA is included. No Apple SDK, Swift compiler, Xcode, signing service or physical iPhone was available in the authoring workspace.

## Completed here

- Parsed every Swift source and XCTest file with the tree-sitter Swift grammar: no error or missing nodes. This checks syntax structure, not Swift types or Apple APIs.
- Parsed the GitHub workflow YAML and checked each shell script with `bash -n`.
- Ran the portable project validator: required source files, manifest safety and duplicate paths, pinned revision URLs, SHA-256 formats, component totals, icon dimensions/opacity, JSON/plist and Python syntax checks passed.
- Retrieved headers from all six selected safetensors shards without downloading the weights. Confirmed the actual 8-bit image tensor names, 6-bit text packing, FP32 offset normalization tensors, FP32 decoder layout, and 252 sets of unmerged FP32 adapter projection tensors match the implementation's expectations.
- Compared official Base/SFT text-encoder shard SHA-256 identities: all four match. This supports using the shared compact text encoder with the Base model.
- Independently reproduced the Swift tokenizer's byte map, pair-ranking and normalization algorithm in Python and compared all seven supplied Unicode, special-token and JSON prompt fixtures against the Rust `tokenizers` library: matches.
- Generated scheduler/noise fixtures from the upstream Python MLX reference implementation for the included Swift XCTest cases. Those Swift tests have not run here. No independent PyTorch binary was installed here.
- Parsed the optional Colab notebook's executable Python cells. The 13.3 GB download/upload job was not run against a user's account.
- Inspected the original SVG/PNG icon artwork and checked three opaque 1024 × 1024 PNG appearance assets.

## Not completed here

- Xcode package resolution, Swift type checking, linking, shader compilation or simulator tests.
- A successful run of the supplied GitHub workflow.
- Unsigned IPA production, Signulous signing, entitlement preservation or installation.
- Physical iPhone execution of any MLX operation or model inference.
- Measured stage memory, timings, thermal behavior, image fidelity, Fast quality or output parity.
- Real-device background downloads, connection-loss recovery, folder provider/bookmark behavior, Photos export, VoiceOver or Dynamic Type review.

The supplied workflow makes a successful Apple build and the reference/integrity tests mandatory before it offers an IPA artifact. It also rejects an archive without its MLX Metal library. A successful workflow is only the next validation stage. The first phone test should use 512 × 512, Balanced, a short prompt, then repeat offline. A lower-resolution 256 × 256 test is available if the normal iOS memory limit is too tight.

If the build or phone test fails, send the unedited error/logs using START-HERE.html. Do not describe this project as production-ready or confirmed compatible until those checks pass.
