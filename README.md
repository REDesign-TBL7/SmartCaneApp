# Smart Cane Monorepo

This repository contains the two runtime codebases for the smart cane system.

## Layout

```
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

## Pi Setup (Full)

### Quick Start (Manual)

```bash
cd pi
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
sudo .venv/bin/python src/main.py
```

The runtime auto-configures AP mode on first run.

### Auto-start on Boot (Recommended)

```bash
# Replace with your actual repo path
REPO_ROOT=/home/pi/SmartCaneApp

# Setup venv
python3 -m venv $REPO_ROOT/pi/.venv
$REPO_ROOT/pi/.venv/bin/pip install -r $REPO_ROOT/pi/requirements.txt

# Install systemd service
sudo cp infra/pi-network/systemd/smartcane-runtime.service /etc/systemd/system/
sudo sed -i "s|__SMARTCANE_REPO_ROOT__|$REPO_ROOT|g" /etc/systemd/system/smartcane-runtime.service

sudo systemctl daemon-reload
sudo systemctl enable smartcane-runtime
sudo systemctl start smartcane-runtime
```

Hot-reload after code changes:
```bash
sudo systemctl reload smartcane-runtime
```

Check status:
```bash
sudo systemctl status smartcane-runtime
journalctl -u smartcane-runtime -f
```

## Pi Commands

```bash
sudo python src/main.py          # Start runtime (auto-setup network)
sudo python src/main.py --setup  # Setup network only
python src/main.py --status      # Check network status
python src/main.py --help        # Show help
```

## WebSocket Endpoint

`ws://192.168.4.1:8080/ws`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SMARTCANE_AP_SSID` | `SmartCane` | WiFi network name |
| `SMARTCANE_AP_PASSPHRASE` | `SmartCane123` | WiFi password |
| `SMARTCANE_AP_IP` | `192.168.4.1` | Pi IP address |
| `SMARTCANE_LOG_LEVEL` | `INFO` | Log level (DEBUG, INFO, WARNING) |

## Connectivity

- iOS cane transport is Wi-Fi only (cellular disabled)
- First-time: Pi hosts `SmartCane` WiFi for phone to connect
- Normal use: Phone connects to Pi's WiFi, Pi advertises via Bonjour

## Setup Guides

- Full testing guide: `docs/testing-guide.md`
- Pi networking: `docs/pi-network-setup.md`
- FastVLM model integration: `docs/fastvlm-integration.md`
