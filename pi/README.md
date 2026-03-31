# Pi Runtime

Python runtime for Raspberry Pi Zero 2W motor control, HC-SR04 ultrasonic sensing,
MPU9250 IMU heading, Pi camera frame streaming, and cane comms.

## Run

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python src/main.py
```

WebSocket server binds to `0.0.0.0:8080`.

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

- Ultrasonic trigger/echo pins (BOARD): `(7,11)`, `(15,16)`, `(22,23)`
- Motor driver channels (BOARD pin numbering for DRV8313):
  - Motor 1: `IN1=25`, `IN2=26`, `IN3=27`, `EN=14`
  - Motor 2: `IN1=32`, `IN2=33`, `IN3=13`, `EN=12`
  - Motor 3: `IN1=18`, `IN2=19`, `IN3=21`, `EN=5`
- MPU9250 over I2C bus 1 at address `0x68`

Motor control uses `GPIO.setmode(GPIO.BOARD)` to match the pin mapping above.
