# ESP32 Motor Controller

This folder contains the ESP32-S3 motor controller sketch for the smart cane.

The Raspberry Pi remains the app-facing runtime:

```text
iOS app -> WebSocket JSON -> Raspberry Pi safety loop -> serial text -> ESP32
```

The ESP32 receives one command per line:

```text
LEFT
RIGHT
FORWARD
STOP
```

The ESP32 also owns the motor-unit IMU. It reports motor-unit orientation back to
the Pi over the same serial link:

```text
MOTOR_IMU <available> <headingDegrees> <pitchDegrees> <rollDegrees>
```

The sketch currently includes the telemetry hook and a TODO inside
`updateMotorUnitImu()`. Wire the real ESP32 IMU driver there once the exact IMU
sensor/library is finalized. Do not use the Pi handle IMU for motor-unit heading;
that handle IMU is reserved for camera deblur/stabilization.

Upload `motor_controller/motor_controller.ino` to the ESP32. The sketch is based
on the original `test_1.ino` DRV8313 pin map and 6-step commutation pattern, but
it waits for Pi serial commands before moving the motors.

Normal baud rate:

```text
115200
```

Important calibration note:

The current direction mapping mirrors the old Pi inverse-kinematics signs:

- `FORWARD`: motor 1 forward, motors 2 and 3 reverse
- `LEFT`: all motors forward
- `RIGHT`: all motors reverse
- `STOP`: all motor phases off

TODO: Test on the physical cane and flip signs in `directionsForCommand(...)` if
the haptic tug direction is inverted.
