# Pi Runtime

Python runtime for Raspberry Pi Zero 2W cane comms, handle-mounted MPU6050 IMU
data for camera deblur backup, Pi camera frame streaming, and ESP32 motor-command /
sensor forwarding.

## Run

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python src/main.py
```

WebSocket server binds to `0.0.0.0:8080`.

## Pi to ESP32 motor link

Motor GPIO control has moved off the Pi. The Pi now forwards the final safety-
checked motor command to the ESP32 over serial.

Default serial discovery order:

- `/dev/ttyUSB0`
- `/dev/ttyACM0`
- `/dev/serial0`

Override if needed:

```bash
export SMARTCANE_ESP32_PORT=/dev/ttyACM0
export SMARTCANE_ESP32_BAUD=115200
python src/main.py
```

The Pi sends one line per command:

```text
LEFT
RIGHT
FORWARD
STOP
```

The ESP32 sketch is in `esp32/motor_controller/motor_controller.ino`.

The Pi also listens for ESP32 telemetry lines:

```text
MOTOR_IMU <available> <headingDegrees> <pitchDegrees> <rollDegrees>
ULTRASONIC <nearestObstacleCm>
```

That motor-unit heading is forwarded to iOS as `motorImuHeadingDegrees`. The ESP32
also owns ultrasonic obstacle sensing for the demo and forwards the nearest
distance as `obstacleDistanceCm`. The Pi's own handle IMU remains available as a
backup and is still forwarded separately as `handleImu...` fields for future
camera deblur/stabilization.

## Phone Hotspot Networking

The Pi runtime serves on `0.0.0.0:8080`. The supported demo deployment flow is:

- iPhone enables Personal Hotspot
- Pi joins that hotspot using credentials from `smartcane-hotspot.json` or BLE provisioning
- Pi advertises BLE diagnostics with its current hotspot IP
- iPhone app reads the Pi IP from BLE diagnostics
- iPhone app connects to `ws://<pi-hotspot-ip>:8080/ws`

First-boot credential file locations:

- `/boot/firmware/smartcane-hotspot.json`
- `/boot/smartcane-hotspot.json`

Example:

```json
{
  "hotspotSSID": "Your iPhone Hotspot Name",
  "hotspotPassword": "your-hotspot-password"
}
```

If the boot file is not present, the Pi runtime now stays alive in BLE provisioning mode and the iPhone app can send the same credentials over BLE.

Optional device identity overrides:

```bash
export SMARTCANE_DEVICE_NAME="Smart Cane Demo"
export SMARTCANE_DEVICE_ID="smartcane-demo-01"
python src/main.py
```

Provisioning / install helpers inside the deployable `pi/` bundle:

- `infra/pi-network/setup.sh`
- `infra/pi-network/smartcane_network.sh`
- `infra/pi-network/generate_cloud_init.sh`
- `infra/pi-network/ota_update.sh`

Recommended one-time install from `pi/`:

```bash
cd /path/to/smartcane-pi
sudo infra/pi-network/setup.sh
```

That install path now also enables Raspberry Pi I2C support for the handle IMU by:

- enabling `dtparam=i2c_arm=on`
- ensuring `i2c-dev` is loaded
- installing `i2c-tools`

After that, `smartcane-runtime.service` starts on boot and auto-imports hotspot credentials from the boot partition if present.

On Raspberry Pi OS images with `cloud-init`, generate `user-data`, `meta-data`, and `network-config` from `pi/` with:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot
```

That generator now stages an offline first-boot payload from the local checkout:

- `smartcane/repo.tar.gz`
- `smartcane/python-vendor.tar.gz`

So the Pi no longer needs network access on first boot to clone the repo or install Python packages.
If internet is already available on first boot, the generated cloud-init also installs the usual OS-side tools; otherwise it skips that step and leaves the image as-is.

If you do not pass `--wheelhouse`, the generator builds that Python payload on the machine where you run it.
The generated first-boot script also writes `smartcane/firstboot.log` onto the boot partition for pre-runtime debugging.

If you want OTA enabled on an offline-seeded image, also pass a GitHub repo URL or explicit manifest URL:

```bash
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --repo-url https://github.com/your-org/REDesign.git \
  --repo-branch main
```

That lets the provisioning scripts derive:

- `https://github.com/<owner>/<repo>/releases/download/pi-latest/smartcane-pi-manifest.json`

You can also pass it directly:

```bash
infra/pi-network/generate_cloud_init.sh \
  --boot /path/to/boot \
  --ota-manifest-url https://github.com/your-org/REDesign/releases/download/pi-latest/smartcane-pi-manifest.json
```

## OTA updates

The Pi install now includes:

- `smartcane-ota.service`
- `smartcane-ota.timer`

The OTA path is Pi-bundle based:

- fetch `smartcane-pi-manifest.json`
- download `smartcane-pi-bundle.tar.gz`
- verify the SHA-256 checksum
- swap the deployed `pi/` bundle in place
- refresh installed `systemd` units from the new bundle
- roll back to the previous bundle if the updated runtime does not come back up
- restart `smartcane-runtime.service`

The GitHub Actions workflow that publishes these artifacts is:

- `.github/workflows/pi-cd.yml`

Manual trigger:

```bash
sudo systemctl start smartcane-ota.service
```

## Hardware mapping

- Handle MPU6050 over I2C bus 1 at address `0x68` on Pi, kept as backup for deblur
- ESP32 handles motor DRV8313 pins in `esp32/motor_controller/motor_controller.ino`
- ESP32 motor unit owns the motor-control IMU
- ESP32 also owns the ultrasonic trigger/echo wiring for the demo

## Handle IMU notes

The Pi-side handle IMU is optional backup hardware. If the MPU6050 is not
reachable over I2C, the runtime now logs a warning and continues instead of
crashing.

Override bus/address if needed:

```bash
export SMARTCANE_HANDLE_IMU_BUS=1
export SMARTCANE_HANDLE_IMU_ADDR=0x68
python src/main.py
```

Useful Pi checks:

```bash
ls /dev/i2c-*
sudo i2cdetect -y 1
```
