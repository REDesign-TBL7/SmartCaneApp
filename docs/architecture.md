# Architecture

## Runtimes

- `ios/`: route guidance, voice UX, FastVLM inference, command generation
- `pi/`: iOS WebSocket server, HC-SR04 sensing, handle-mounted IMU for camera deblur, heartbeat safety, telemetry, camera frame uplink, and final command forwarding to ESP32
- `esp32/`: DRV8313 motor control from Pi serial commands plus the motor-unit IMU used for haptic motor guidance

## Safety

Pi runtime is authoritative for emergency stop logic before any command reaches
the ESP32 motor controller.

## Data Flow

1. iOS sends command + heartbeat, including phone GPS coordinates.
2. Pi updates location proxy from heartbeat GPS and applies safety arbitration.
3. Pi applies safety arbitration, forwards the final motor command to ESP32,
   streams telemetry, and streams camera JPEG frames.
4. iOS runs FastVLM on Pi-camera frames and refines spoken guidance.

## Motor command path

`iOS app -> WebSocket JSON -> Raspberry Pi safety loop -> serial line -> ESP32`

The Pi forwards `LEFT`, `RIGHT`, `FORWARD`, or `STOP` as newline-terminated serial
commands. The ESP32 owns the DRV8313 pin sequencing.

## IMU ownership

- Motor-unit IMU: mounted on the ESP32 motor unit and used for motor/tip heading.
- Handle IMU: mounted on the cane handle, read by the Pi, and reserved for camera deblur/stabilization.
- iOS guidance should use `motorImuHeadingDegrees` for heading-based cane commands.
- Camera/VLM stabilization should use the `handleImu...` telemetry fields.

## Network policy

- iOS cane transport disables cellular access at URLSession level.
- Cane connection is only attempted while Wi-Fi interface is active.

## Outdoor connectivity profiles

- `AUTO`: prefers phone hotspot endpoint (`172.20.10.2`), fallback profile is Pi AP endpoint (`192.168.4.1`).
- `PHONE_HOTSPOT`: use when outdoors to retain cellular internet and local Wi-Fi cane link.
- `PI_AP`: direct connection to Pi-hosted access point when hotspot is unavailable.

Both endpoint modes are implemented in iOS transport selection only. The Pi server code
always binds `0.0.0.0:8080`; AP vs hotspot is determined by Linux network config on Pi.
