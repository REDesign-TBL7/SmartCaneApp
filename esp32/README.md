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

Windows build helper:

- [build_ota_bin_windows.bat](/Users/hanyuxuan/Desktop/REDesign/esp32/build_ota_bin_windows.bat)
- [build_ota_bin_windows.ps1](/Users/hanyuxuan/Desktop/REDesign/esp32/build_ota_bin_windows.ps1)

On Windows, the fastest OTA workflow is:

1. Install `arduino-cli`.
2. Install the ESP32 core once:

```powershell
arduino-cli core update-index
arduino-cli core install esp32:esp32
```

3. From the repo root, run:

```powershell
.\esp32\build_ota_bin_windows.bat
```

Or from inside the `esp32` folder, run:

```powershell
.\build_ota_bin_windows.bat
```

4. The script writes the OTA app binary to:

```text
esp32\build\esp32-ota\smartcane_esp32_ota.bin
```

5. Connect to `ESP32_OMNI_BOT`, open `http://192.168.4.1/update`, and upload
   that `.bin`.

The default board target is:

```text
esp32:esp32:esp32s3
```

If your exact ESP32-S3 board definition is different, pass it explicitly:

```powershell
.\esp32\build_ota_bin_windows.bat -Fqbn esp32:esp32:esp32s3
```

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

Current avoidance roles:

- Sensor 1 = right side
- Sensor 3 = left side
- Sensor 4 = front
- Sensor 2 is still sampled and reported, but is not used as the primary front trigger

Current local ESP32 avoidance behavior:

- on boot, avoidance stays inactive until the ultrasonic readings have settled
- if sensor 4 reports an obstacle within about `5 cm`, the cane reverses once
  for about `0.25 s`
- while reversing, it compares the best clearance seen on sensor 1 and sensor 3
- it then sidesteps toward the side with the greater clearance
- it will not re-trigger front avoidance until sensor 4 clears again
- if sensor 1 is the closest side obstacle within about `5 cm`, it sidesteps
  left
- if sensor 3 is the closest side obstacle within about `5 cm`, it sidesteps
  right

This avoidance runs locally on the ESP32 and temporarily overrides Pi
navigation commands so the response does not depend on app/Pi round-trip time.

Important calibration note:

The current serial command mapping is translated onto the omni-drive mixer:

- `FORWARD`: mapped to forward translation for the current mirrored motor wiring
- `LEFT`: mapped to leftward translation / pull for the current mirrored motor wiring
- `RIGHT`: mapped to rightward translation / pull for the current mirrored motor wiring
- `STOP`: all motor phases off

If wheel directions are inverted, flip `INVERT_M1`, `INVERT_M2`, and
`INVERT_M3` in the sketch.
