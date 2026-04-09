# Pi Runtime

Python runtime for Raspberry Pi Zero 2W cane comms, handle-mounted MPU9250 IMU
data for camera deblur, Pi camera frame streaming, and ESP32 motor-command /
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

## AP vs hotspot

Pi AP mode is not a Python switch. The Python runtime always serves on `0.0.0.0:8080`.
Whether the phone connects through Pi AP or phone hotspot depends on Pi Linux network setup
(hostapd/dnsmasq for AP, or normal Wi-Fi client config for hotspot).

Provisioning scripts are included in `infra/pi-network/`:

- `setup_ap_mode.sh`
- `setup_hotspot_client_mode.sh`
- `check_network_mode.sh`
- `use_mode.sh` (single command mode switch)
- `install_runtime_service.sh`

## Hardware mapping

- Handle MPU9250 over I2C bus 1 at address `0x68` on Pi, kept as backup for deblur
- ESP32 handles motor DRV8313 pins in `esp32/motor_controller/motor_controller.ino`
- ESP32 motor unit owns the motor-control IMU
- ESP32 also owns the ultrasonic trigger/echo wiring for the demo
