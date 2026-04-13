# Deployment Runbook

## Targets

- iPhone app: [ios/](/Users/hanyuxuan/Desktop/REDesign/ios)
- Pi bundle: [pi/](/Users/hanyuxuan/Desktop/REDesign/pi)
- ESP32 firmware: [esp32/](/Users/hanyuxuan/Desktop/REDesign/esp32)

## 1. Publish Pi OTA Artifact

Make Pi-side changes only under:

- [pi/runtime](/Users/hanyuxuan/Desktop/REDesign/pi/runtime)
- [pi/infra](/Users/hanyuxuan/Desktop/REDesign/pi/infra)

Push to `main`.

GitHub Actions in [pi-cd.yml](/Users/hanyuxuan/Desktop/REDesign/.github/workflows/pi-cd.yml:1) publishes:

- `smartcane-pi-bundle.tar.gz`
- `smartcane-pi-manifest.json`
- `smartcane-pi-sha256.txt`

Release tag:

- `pi-latest`

Canonical OTA manifest URL:

- `https://github.com/<owner>/<repo>/releases/download/pi-latest/smartcane-pi-manifest.json`

## 2. Flash ESP32

Flash [motor_controller.ino](/Users/hanyuxuan/Desktop/REDesign/esp32/motor_controller/motor_controller.ino:1) to the ESP32.

Reference:

- [esp32/README.md](/Users/hanyuxuan/Desktop/REDesign/esp32/README.md:1)

Expected serial baud:

- `115200`

## 3. Provision Pi

### Option A: Offline cloud-init image prep

Run from the Pi bundle root:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --repo-on-pi /home/pi/smartcane-pi \
  --repo-url https://github.com/<owner>/<repo>.git \
  --hotspot-ssid "Your iPhone Hotspot Name" \
  --hotspot-password "your-hotspot-password" \
  --ssh-password "your-ssh-password"
```

This stages:

- the Pi bundle itself
- vendored Python dependencies
- `smartcane-runtime.service`
- `smartcane-ota.service`
- `smartcane-ota.timer`
- the OTA manifest URL

### Option B: Mounted-image staging

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/stage_image.sh \
  --root /path/to/rootfs \
  --boot /path/to/boot \
  --repo-on-pi /home/pi/smartcane-pi \
  --ota-manifest-url https://github.com/<owner>/<repo>/releases/download/pi-latest/smartcane-pi-manifest.json \
  --hotspot-ssid "Your iPhone Hotspot Name" \
  --hotspot-password "your-hotspot-password"
```

### Option C: Live install on a Pi that already has the bundle copied over

Copy only [pi/](/Users/hanyuxuan/Desktop/REDesign/pi) to the Pi, for example to `/home/pi/smartcane-pi`.

If that copied bundle is not a Git checkout, set the OTA manifest explicitly before install:

```bash
cd /home/pi/smartcane-pi
export SMARTCANE_OTA_MANIFEST_URL="https://github.com/<owner>/<repo>/releases/download/pi-latest/smartcane-pi-manifest.json"
sudo infra/pi-network/setup.sh
```

## 4. Install iPhone App

Open [ios/SmartCaneApp.xcodeproj](/Users/hanyuxuan/Desktop/REDesign/ios/SmartCaneApp.xcodeproj) in Xcode and run the `SmartCaneApp` scheme on a physical iPhone.

## 5. First Boot / Demo Bring-Up

1. Turn on iPhone Personal Hotspot.
2. Power the ESP32 and Pi.
3. The Pi starts `smartcane-runtime.service`.
4. If hotspot credentials are already present, the Pi joins the hotspot.
5. If not, the Pi stays up in BLE provisioning mode.
6. Open the app and use BLE diagnostics/provisioning to send hotspot credentials if needed.
7. The app reads the Pi IP from BLE.
8. The app connects to `ws://<pi-ip>:8080/ws`.
9. ESP32 receives final motor commands from the Pi over serial.

## 5A. ESP32 Backup Remote Control

Use this if the Pi runtime or app path becomes unreliable during the demo.

1. Join the ESP32 AP:
   - SSID `ESP32_OMNI_BOT`
   - password `12345678`
2. Open `http://192.168.4.1`
3. Tap `Arm backup override`
4. Use the joystick or quick buttons to drive the motors directly
5. Adjust `Translate speed` and `Rotate speed` sliders as needed for the demo floor
6. Watch the live status card:
   - control source
   - obstacle distance
   - applied motion vector
   - wheel mix
7. Release backup override when returning control to the Pi

## 6. Pi OTA Update

Automatic path:

- `smartcane-ota.timer` checks every 30 minutes

Manual trigger:

```bash
sudo systemctl start smartcane-ota.service
```

OTA flow:

1. Download `smartcane-pi-manifest.json`
2. Compare version with local `VERSION`
3. Download `smartcane-pi-bundle.tar.gz`
4. Verify SHA-256
5. Swap the deployed `/home/pi/smartcane-pi` bundle in place
6. Preserve `runtime/logs`
7. Restart `smartcane-runtime.service`
8. Roll back automatically if the new runtime fails health check

## 7. Runtime Checks

Pi runtime log:

```bash
tail -f /home/pi/smartcane-pi/runtime/logs/pi_runtime.log
```

OTA log:

```bash
tail -f /var/log/smartcane-ota.log
```

Service status:

```bash
systemctl status smartcane-runtime smartcane-ota.service smartcane-ota.timer --no-pager
```

## 8. Wireless Recovery Path

- If Wi-Fi connection fails, use BLE diagnostics from the iPhone app.
- If OTA fails, the Pi should roll back automatically to the previous bundle.
- If provisioning fails before runtime is reachable, inspect the cloud-init boot log from the SD card:
  - `smartcane/firstboot.log`
