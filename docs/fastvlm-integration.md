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

## Model delivery

The app now auto-downloads the FastVLM model on first launch and stores it under the app sandbox
(`Application Support/FastVLM/model`). The model is mandatory, but it is no longer bundled into
the app target.

Manual fallback is still available:

```bash
chmod +x ios/scripts/get_fastvlm_model.sh
ios/scripts/get_fastvlm_model.sh 0.5b ios/FastVLMAssets/model
```

Model options: `0.5b`, `1.5b`, `7b`.

## Xcode integration steps

1. Open `ios/SmartCaneApp.xcodeproj`.
2. Select the project, then `Package Dependencies`, and add:
   - `https://github.com/ml-explore/mlx-swift-lm` (up to next minor)
   - `https://github.com/huggingface/swift-transformers` (up to next minor)
3. In target `SmartCaneApp` under `Frameworks, Libraries, and Embedded Content`, add package products:
   - `MLXLMCommon`
   - `MLXVLM`
   - `Tokenizers`
4. Ensure `MLXLMCommon`, `MLXVLM`, `Tokenizers`, and `Hub` imports resolve where needed.
5. This repo already auto-wires `FastVLMAppleEngine` in `ios/SmartCaneApp/App/SmartCaneApp.swift` behind `#if canImport(...)` guards.
6. On first app launch, allow the automatic model download to complete.
7. Validate one frame end-to-end by checking `CVModelView` summary text updates during navigation.

## Important dependency note

The app now uses `MLXVLM` directly with a local FastVLM model directory, so no separate
`FastVLM` framework target is required.

## Minimal implementation pattern

The app is already structured for this shape:

- `FastVLMEngine.inferHazardSummary(from:)` receives JPEG bytes.
- Return one concise sentence focused on mobility hazards.
- `VisionManager` converts sentence into tags (`stairs_ahead`, `curb`, `pedestrian`, etc.).

## Recommended runtime settings

- Start with FastVLM `0.5b` for latency on iPhone.
- Inference cadence: `1-2 Hz` while navigating.
- Keep hazard prompt short and stable across requests.
