# Smart Cane Monorepo

This repository contains the app, embedded, and Pi runtime codebases for the smart cane system.

## Layout

```text
ios/       SwiftUI app for navigation, voice UX, and on-device FastVLM inference
pi/        Deployable Pi bundle containing runtime/ and infra/
esp32/     Arduino motor controller for DRV8313 motor sequencing and motor-unit IMU telemetry
protocol/  Shared JSON protocol schema between iOS and Pi
docs/      Architecture, safety, and calibration notes
```

`pi/` is the only subtree that needs to be copied to the Pi.
The root-level `infra/` path is a compatibility symlink into `pi/infra`.

## Run iOS app

1. Open `ios/SmartCaneApp.xcodeproj` in Xcode.
2. Choose an iPhone simulator or physical iPhone.
3. Build and run the `SmartCaneApp` scheme.

## Pi Setup (Full)

### Option 1: One-command Install (Recommended)

On Pi, run as root from the uploaded `pi/` bundle:

```bash
cd /path/to/smartcane-pi
sudo infra/pi-network/setup.sh
```

This installs packages, configures OTA, sets up the runtime, and starts the service.

### Option 2: Manual Setup

```bash
cd /path/to/smartcane-pi/runtime
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
sudo .venv/bin/python src/main.py
```

The runtime stays in hotspot-client / BLE provisioning flow instead of Pi AP mode.

### Option 3: Service with Custom Path

```bash
# Replace with your actual repo path
REPO_ROOT=/home/pi/smartcane-pi

# Setup venv
python3 -m venv $REPO_ROOT/runtime/.venv
$REPO_ROOT/runtime/.venv/bin/pip install -r $REPO_ROOT/runtime/requirements.txt

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

## OTA

Pi OTA is Pi-only. The Pi downloads a published `pi/` bundle from GitHub releases instead of pulling the whole monorepo.

Publisher workflow:

- `.github/workflows/pi-cd.yml`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SMARTCANE_AP_SSID` | `SmartCane` | WiFi network name |
| `SMARTCANE_AP_PASSPHRASE` | `SmartCane123` | WiFi password |
| `SMARTCANE_AP_IP` | `192.168.4.1` | Pi IP address |
| `SMARTCANE_LOG_LEVEL` | `INFO` | Log level (DEBUG, INFO, WARNING) |

## Connectivity

- BLE handles hotspot provisioning and Pi diagnostics.
- The Pi joins the iPhone Personal Hotspot for the demo path.
- The app reads the Pi runtime IP from BLE diagnostics and connects over Wi-Fi.

## Setup Guides

- Full testing guide: `docs/testing-guide.md`
- Pi networking: `docs/pi-network-setup.md`
- Deployment runbook: `docs/deployment-runbook.md`
- FastVLM model integration: `docs/fastvlm-integration.md`
