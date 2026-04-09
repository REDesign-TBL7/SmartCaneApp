# FastVLM Integration Guide (Pi Camera -> iPhone Inference)

This project follows the FastVLM approach from `apple/ml-fastvlm`, but uses a split runtime:

- Pi sends JPEG camera frames over local WebSocket.
- iPhone runs FastVLM inference on-device.

## Source reference

- Repository: `https://github.com/apple/ml-fastvlm`
- Relevant folders:
  - `app/FastVLM/FastVLM.swift`
  - `app/FastVLM/MediaProcessingExtensions.swift`
  - `app/get_pretrained_mlx_model.sh`

## What is already wired in this repo

- Pi camera stream packet type: `CAMERA_FRAME` in `protocol/cane_protocol_v1.json`
- Frame receive + decode: `ios/SmartCaneApp/Managers/CaneConnectionManager.swift`
- VLM loop and hazard extraction: `ios/SmartCaneApp/Managers/VisionManager.swift`
- Injection interface for real model: `FastVLMEngine` protocol in `ios/SmartCaneApp/Managers/VisionManager.swift`

## Download model files

Use the helper script (based on Apple script behavior):

```bash
chmod +x ios/scripts/get_fastvlm_model.sh
ios/scripts/get_fastvlm_model.sh 0.5b ios/Resources/FastVLM/model
```

Model options: `0.5b`, `1.5b`, `7b`.

## Xcode integration steps

1. Open `ios/SmartCaneApp.xcodeproj`.
2. Select the project, then `Package Dependencies`, and add:
   - `https://github.com/ml-explore/mlx-swift` (up to next major)
   - `https://github.com/ml-explore/mlx-swift-examples` (up to next major)
   - `https://github.com/huggingface/swift-transformers` (up to next major)
3. In target `SmartCaneApp` under `Frameworks, Libraries, and Embedded Content`, add package products:
   - `MLX`
   - `MLXLMCommon`
   - `MLXVLM`
4. Add `FastVLM` source files from Apple repo as local package/framework or vendored target if needed.
5. Add model directory (`ios/Resources/FastVLM/model`) to app bundle resources.
6. Ensure `FastVLM` and `MLXVLM` imports resolve in `FastVLMAppleEngine.swift`.
7. This repo already auto-wires `FastVLMAppleEngine` in `ios/SmartCaneApp/App/SmartCaneApp.swift` behind `#if canImport(...)` guards.
8. Validate one frame end-to-end by checking `CVModelView` summary text updates during navigation.

## Important dependency note

Apple's `FastVLM` repo provides FastVLM framework source under `app/FastVLM`. You need that
framework available to this project (via local package/target integration) for the concrete
engine to compile and run.

## Minimal implementation pattern

The app is already structured for this shape:

- `FastVLMEngine.inferHazardSummary(from:)` receives JPEG bytes.
- Return one concise sentence focused on mobility hazards.
- `VisionManager` converts sentence into tags (`stairs_ahead`, `curb`, `pedestrian`, etc.).

## Recommended runtime settings

- Start with FastVLM `0.5b` for latency on iPhone.
- Inference cadence: `1-2 Hz` while navigating.
- Keep hazard prompt short and stable across requests.
