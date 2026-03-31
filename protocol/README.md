# Protocol

Shared message schema between iOS app and Raspberry Pi runtime.

- Source of truth: `cane_protocol_v1.json`
- Transport: WebSocket JSON
- Versioning: increment `protocolVersion` for breaking changes

Message families:
- `DISCRETE_CMD` and `HEARTBEAT` from iOS to Pi
- `TELEMETRY` and `CAMERA_FRAME` from Pi to iOS
