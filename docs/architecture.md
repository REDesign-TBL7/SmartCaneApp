# Architecture

## Runtimes

- `ios/`: route guidance, voice UX, FastVLM inference, command generation
- `pi/`: motor control, HC-SR04 sensing, MPU9250 heading, heartbeat safety, telemetry, camera frame uplink

## Safety

Pi runtime is authoritative for emergency stop logic.

## Data Flow

1. iOS sends command + heartbeat, including phone GPS coordinates.
2. Pi updates location proxy from heartbeat GPS and applies safety arbitration.
3. Pi actuates motors, streams telemetry, and streams camera JPEG frames.
4. iOS runs FastVLM on Pi-camera frames and refines spoken guidance.

## Network policy

- iOS cane transport disables cellular access at URLSession level.
- Cane connection is only attempted while Wi-Fi interface is active.

## Outdoor connectivity profiles

- `AUTO`: prefers phone hotspot endpoint (`172.20.10.2`), fallback profile is Pi AP endpoint (`192.168.4.1`).
- `PHONE_HOTSPOT`: use when outdoors to retain cellular internet and local Wi-Fi cane link.
- `PI_AP`: direct connection to Pi-hosted access point when hotspot is unavailable.

Both endpoint modes are implemented in iOS transport selection only. The Pi server code
always binds `0.0.0.0:8080`; AP vs hotspot is determined by Linux network config on Pi.
