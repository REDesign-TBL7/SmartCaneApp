# Protocol

Shared message schema between iOS app and Raspberry Pi runtime.

- Source of truth: `cane_protocol_v1.json`
- Transport: WebSocket JSON
- Versioning: increment `protocolVersion` for breaking changes

Message families:
- `PAIR_HELLO`, `DISCRETE_CMD`, `HEARTBEAT`, and `DEBUG_PING` from iOS to Pi
- `PAIR_INFO`, `TELEMETRY`, `CAMERA_FRAME`, and `DEBUG_PONG` from Pi to iOS

Wi-Fi pairing:
- iOS discovers the setup service over Bonjour / mDNS (`_smartcane-setup._tcp`) during first-time onboarding.
- iOS first discovers the Pi over Bonjour / mDNS (`_smartcane._tcp`) when available.
- iOS sends `PAIR_HELLO` when first connecting over the phone hotspot WebSocket path.
- Pi responds with `PAIR_INFO`, including a stable device name and device ID.
- The app stores that paired device locally so reconnecting is one tap later.

Debug connectivity:
- `DEBUG_PING` lets the app verify the phone-to-Pi WebSocket path end to end.
- Pi responds immediately with `DEBUG_PONG`, echoing the `debugLabel`.
- App can use this to show round-trip time and confirm command transport health.

Motor command bridge:
- After Pi safety checks, the Pi forwards either:
  - `MOVE <vx> <vy> <wz>` for speed-scaled omni-drive motion, or
  - `LEFT`, `RIGHT`, `FORWARD`, `STOP` as fallback discrete commands
  to the ESP32 as newline-terminated serial text.
- The ESP32 owns DRV8313 motor pin sequencing.
- The ESP32 also owns the motor-unit IMU and reports `MOTOR_IMU ...` serial lines
  back to the Pi.

IMU telemetry:
- `motorImu...` fields come from the ESP32 motor unit and are for motor guidance.
- `handleImu...` fields come from the Pi handle IMU and are for camera deblur.
- `headingDegrees` is legacy; new clients should prefer `motorImuHeadingDegrees`.
