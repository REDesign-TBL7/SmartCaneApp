# Smart Cane Monorepo

This repository contains the two runtime codebases for the smart cane system.

## Layout

```text
ios/       SwiftUI app for navigation, voice UX, and on-device FastVLM inference
pi/        Python runtime for WebSocket comms, sensors, handle IMU, camera streaming, and ESP32 command forwarding
esp32/     Arduino motor controller for DRV8313 motor sequencing and motor-unit IMU telemetry
protocol/  Shared JSON protocol schema between iOS and Pi
docs/      Architecture, safety, and calibration notes
infra/     Pi network provisioning and service install scripts
```

## Run iOS app

1. Open `ios/SmartCaneApp.xcodeproj` in Xcode.
2. Choose an iPhone simulator or physical iPhone.
3. Build and run the `SmartCaneApp` scheme.

## Run Pi runtime

```bash
cd pi
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python src/main.py
```

WebSocket endpoint defaults to `ws://<pi-ip>:8080/ws`.

The Pi forwards safety-checked motor commands to the ESP32 over serial. The ESP32
sketch is in `esp32/motor_controller/motor_controller.ino`.

IMU split:

- ESP32 motor-unit IMU: motor/tip orientation for haptic guidance.
- Pi handle IMU (MPU6050 backup): handle motion for future camera deblur/stabilization.

## Connectivity behavior

- The iOS cane transport is Wi-Fi only and explicitly disables cellular usage.
- This keeps phone-to-cane traffic off cellular data even when mobile data is enabled.
- Network modes:
  - `Auto`: prefers phone hotspot endpoint then Pi AP profile.
  - `Hotspot`: best for outdoor usage with phone cellular internet preserved.
  - `Pi AP`: direct cane AP link.

## Setup guides

- Full testing guide: `docs/testing-guide.md`
- Pi networking and service setup: `docs/pi-network-setup.md`
- FastVLM model and app integration: `docs/fastvlm-integration.md`

## Xcode quick path

1. Open `ios/SmartCaneApp.xcodeproj`.
2. Add package dependencies listed in `docs/fastvlm-integration.md`.
3. Download model files: `ios/scripts/get_fastvlm_model.sh 0.5b ios/Resources/FastVLM/model`.
4. Add `ios/Resources/FastVLM/model` into target resources.
5. Build and run on a physical iPhone.
