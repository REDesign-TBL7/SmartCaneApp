# Architecture

## Runtimes

- `ios/`: route guidance, voice UX, FastVLM inference, command generation
- `pi/`: iOS WebSocket server, handle-mounted IMU backup for camera deblur, heartbeat safety, telemetry, camera frame uplink, and final command forwarding to ESP32
- `esp32/`: DRV8313 motor control from Pi serial commands plus the motor-unit IMU and ultrasonic sensing used for demo safety input

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
commands. The ESP32 owns the DRV8313 pin sequencing and reports obstacle
distance back over serial.

## IMU ownership

- Motor-unit IMU: mounted on the ESP32 motor unit and used for motor/tip heading.
- Handle IMU: mounted on the cane handle, read by the Pi, and reserved for camera deblur/stabilization.
- iOS guidance should use `motorImuHeadingDegrees` for heading-based cane commands.
- Camera/VLM stabilization should use the `handleImu...` telemetry fields.

## Network policy

- iOS cane transport disables cellular access at URLSession level.
- Cane connection is only attempted while Wi-Fi interface is active.

## Connectivity profile

- `PI_ACCESS_POINT`: the Pi always hosts the `SmartCane` Wi-Fi network on `192.168.4.1/24`.
- The iPhone joins that Wi-Fi network directly and opens `ws://192.168.4.1:8080/ws`.
- There is no hotspot switching, setup HTTP service, or Bonjour / mDNS discovery in the active connection path.
- The Pi server always binds `0.0.0.0:8080`; the app uses the fixed AP gateway address.
