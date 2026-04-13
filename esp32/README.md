# ESP32 Motor Controller

This folder contains the ESP32-S3 motor controller sketch for the smart cane.

The Raspberry Pi remains the app-facing runtime:

```text
iOS app -> WebSocket JSON -> Raspberry Pi safety loop -> serial text -> ESP32
```

The ESP32 accepts one command per line from the Pi over GPIO UART:

```text
LEFT
RIGHT
FORWARD
STOP
```

Current ESP32 UART pins:

- `GPIO42` = RX from Pi TX
- `GPIO41` = TX to Pi RX
- shared `GND`

Baud:

```text
115200
```

The sketch also exposes the same direct AP joystick controller as the reference
test sketch for bench testing and demo fallback:

```text
SSID: ESP32_OMNI_BOT
PASS: 12345678
URL:  http://192.168.4.1
```

Wi-Fi firmware update is also enabled on the same AP:

```text
URL: http://192.168.4.1/update
```

Use that page to upload the compiled `.bin` firmware image and reboot the board
without USB reflashing.

That page is intentionally kept aligned with the standalone reference sketch:

- move joystick
- rotate joystick
- center
- stop

Web or Pi serial input both feed the same underlying `vx / vy / wz` control
targets and the same motor commutation loop.

The ESP32 also owns the motor-unit IMU and the ultrasonic obstacle sensors used
for the demo. It reports both back to the Pi over the same serial link:

```text
MOTOR_IMU <available> <headingDegrees> <pitchDegrees> <rollDegrees>
ULTRASONIC <nearestObstacleCm>
```

The motor-unit IMU is now implemented for an `MPU6050` on the ESP32 I2C bus.
The sketch wakes and configures the MPU6050 directly over `Wire`, calibrates
gyro bias at startup, and reports:

- integrated yaw/heading from gyro Z
- complementary-filter pitch
- complementary-filter roll

Do not use the Pi handle IMU for motor-unit heading; that handle IMU is
reserved for camera deblur/stabilization.

Current IMU wiring:

- `GPIO38` = SDA
- `GPIO39` = SCL
- `3.3V` = VCC
- `GND` = GND
- MPU6050 default I2C address = `0x68`

Important MPU6050 note:

- heading is gyro-integrated and will drift over time because the MPU6050 does
  not provide a magnetometer
- this is acceptable for short demo steering cues, but not as a long-duration
  absolute compass

Upload `motor_controller/motor_controller.ino` to the ESP32. The sketch keeps
the original DRV8313 6-step commutation pattern, but now uses the tuned
omni-drive mixing/ramping path from the standalone remote-control sketch under
both control modes:

- Pi serial commands: `LEFT`, `RIGHT`, `FORWARD`, `STOP`
- Wi-Fi AP + browser joystick testing

Ultrasonic note:

- Sensor 1: `GPIO16` trigger, `GPIO17` echo
- Sensor 2: `GPIO18` trigger, `GPIO19` echo
- Sensor 3: `GPIO20` trigger, `GPIO21` echo
- Sensor 4: `GPIO35` trigger, `GPIO36` echo

Important calibration note:

The current serial command mapping is translated onto the omni-drive mixer:

- `FORWARD`: mapped to forward translation
- `LEFT`: mapped to leftward translation / pull
- `RIGHT`: mapped to rightward translation / pull
- `STOP`: all motor phases off

If wheel directions are inverted, flip `INVERT_M1`, `INVERT_M2`, and
`INVERT_M3` in the sketch.
