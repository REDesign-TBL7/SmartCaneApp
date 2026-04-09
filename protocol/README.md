# Protocol

Shared message schema between iOS app and Raspberry Pi runtime.

- Source of truth: `cane_protocol_v1.json`
- Transport: WebSocket JSON
- Versioning: increment `protocolVersion` for breaking changes

Message families:
- `DISCRETE_CMD` and `HEARTBEAT` from iOS to Pi
- `TELEMETRY` and `CAMERA_FRAME` from Pi to iOS

Motor command bridge:
- After Pi safety checks, the Pi forwards `LEFT`, `RIGHT`, `FORWARD`, or `STOP`
  to the ESP32 as newline-terminated serial text.
- The ESP32 owns DRV8313 motor pin sequencing.
- The ESP32 also owns the motor-unit IMU and reports `MOTOR_IMU ...` serial lines
  back to the Pi.

IMU telemetry:
- `motorImu...` fields come from the ESP32 motor unit and are for motor guidance.
- `handleImu...` fields come from the Pi handle IMU and are for camera deblur.
- `headingDegrees` is legacy; new clients should prefer `motorImuHeadingDegrees`.
