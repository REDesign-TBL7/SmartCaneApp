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

## Phone hotspot networking

The Pi runtime always serves on `0.0.0.0:8080`. The supported deployment flow is:

- If no hotspot config exists, bootstrap switches the Pi into setup AP mode:
  - SSID `SmartCaneSetup`
  - passphrase `SmartCaneSetup123`
  - setup server `http://192.168.4.1:8081`
- iPhone app joins the setup AP and sends hotspot credentials to `/setup/hotspot`
- Pi switches into iPhone-hotspot client mode
- Pi advertises itself over mDNS / Bonjour as `_smartcane._tcp`
- iPhone app discovers the Pi by service name and device ID, then connects to the resolved WebSocket endpoint
- app sends `PAIR_HELLO` and stores the returned cane name/ID locally

If mDNS is temporarily unavailable, the app still falls back to `ws://172.20.10.2:8080/ws`.

Optional device identity overrides:

```bash
export SMARTCANE_DEVICE_NAME="Smart Cane Demo"
export SMARTCANE_DEVICE_ID="smartcane-demo-01"
python src/main.py
```

Provisioning scripts are included in `infra/pi-network/`:

- `setup_ap_mode.sh`
- `bootstrap_network_mode.sh`
- `setup_hotspot_client_mode.sh`
- `check_network_mode.sh`
- `use_mode.sh`
- `install_runtime_service.sh`

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
