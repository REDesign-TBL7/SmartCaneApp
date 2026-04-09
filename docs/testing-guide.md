# Smart Cane Testing Guide

This guide covers the current full system:

```text
iOS app -> Wi-Fi WebSocket -> Raspberry Pi safety/runtime -> serial -> ESP32 motors
```

Use this guide in stages. Do not start with the motors attached to the cane tip.
First test software, then serial, then motor bench behavior, then full integration.

## 0) Safety Rules Before Every Hardware Test

- Keep the cane tip lifted or the motor balls off the ground during first tests.
- Keep USB power or a physical power switch reachable.
- Start with `STOP`, then test one direction at a time.
- Do not walk with the device until `STOP` works reliably from the app and from Pi safety logic.
- If a motor spins the wrong way, stop testing and fix the ESP32 direction mapping before continuing.

## 1) Repo Sanity Check

From the repo root:

```bash
cd /Users/hanyuxuan/Desktop/REDesign
git status
```

Expected:

- You should see only intentional local changes.
- No `__pycache__`, `.pyc`, Xcode `DerivedData`, or Arduino build folders should be committed.

Optional formatting/syntax checks:

```bash
git diff --check
python3 -m py_compile pi/src/*.py
```

Expected:

- `git diff --check` prints nothing.
- `py_compile` exits without errors.

## 2) iOS App Build Test

Open the app in Xcode:

```text
ios/SmartCaneApp.xcodeproj
```

Run on a physical iPhone when testing:

- real location
- VoiceOver gestures
- Wi-Fi link to Pi
- camera/VLM flow

Run on simulator only for:

- basic UI layout checks
- non-hardware navigation flow

CLI build check:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project /Users/hanyuxuan/Desktop/REDesign/ios/SmartCaneApp.xcodeproj \
  -scheme SmartCaneApp \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Expected:

- `BUILD SUCCEEDED`

If this fails with `CoreSimulatorService` or `DerivedData` permission errors, open Xcode and build from the app instead. Those errors are usually local Xcode environment issues, not app code errors.

## 3) iOS VoiceOver Accessibility Test

On iPhone:

```text
Settings -> Accessibility -> VoiceOver -> On
```

Home screen expected focus order:

1. Connection status button
2. Network mode controls
3. Current navigation button
4. FastVLM entry
5. Read menu button
6. Speak button
7. Profile button

Test:

- Swipe right through the home screen.
- Double-tap `Disconnected` to connect to the cane.
- Double-tap `No current navigation` to open destination search.
- Search for a place.
- Double-tap a result.
- Confirm the home screen now speaks the selected destination/instruction.

Strict blind-user test:

- Turn VoiceOver on.
- Triple-tap with three fingers to enable Screen Curtain.
- Try the same flow without looking at the screen.

Pass criteria:

- Every important control is reachable by swiping.
- Buttons are understandable without seeing the screen.
- The map is not required.
- User can start navigation with minimal steps.

## 4) iOS Navigation Logic Test

Files involved:

- `ios/SmartCaneApp/Managers/LocationManager.swift`
- `ios/SmartCaneApp/Managers/GuidanceFusionManager.swift`
- `ios/SmartCaneApp/Managers/CaneConnectionManager.swift`

Expected routing stack:

- Search: Apple MapKit search
- Directions: Apple `MKDirections`
- Walking mode: `request.transportType = .walking`
- Motor command conversion: `LEFT`, `RIGHT`, `FORWARD`, `STOP`
- Safety arbitration: `GuidanceFusionManager`

Test:

1. Run app on iPhone.
2. Allow location access.
3. Search a nearby place.
4. Select a result.
5. Watch Xcode logs or app status messages for the outgoing command.

Pass criteria:

- A destination appears as current navigation.
- A route instruction is generated.
- Direction command goes through `GuidanceFusionManager.applyFusedCommand(...)`, not directly to the connection manager.

Important current behavior:

- Obstacle/fault safety currently overrides route guidance by sending `STOP`.
- The app does not yet generate obstacle-avoidance `LEFT` or `RIGHT` corrections from obstacle position.

## 5) Pi Runtime Local Test Without Hardware

On Mac or Pi:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 -m py_compile src/*.py
python src/main.py
```

Expected without Pi hardware:

- Some hardware modules may fall back or report unavailable sensor values.
- If no ESP32 serial port is found, telemetry status should say:

```text
No ESP32 serial port found
```

This is acceptable for software-only testing.

Stop the runtime with:

```text
Control-C
```

## 6) Pi WebSocket Protocol Test

Install a WebSocket client if needed:

```bash
python3 -m pip install websockets
```

Run the Pi runtime:

```bash
cd /path/to/your/repo/pi
source .venv/bin/activate
python src/main.py
```

From another terminal on the same network:

```bash
python3 - <<'PY'
import asyncio
import json
import websockets

async def main():
    uri = "ws://<pi-ip>:8080/ws"
    async with websockets.connect(uri) as ws:
        await ws.send(json.dumps({
            "type": "DISCRETE_CMD",
            "protocolVersion": 1,
            "timestampMs": 0,
            "command": "FORWARD",
            "instructionText": "Test forward"
        }))
        await ws.send(json.dumps({
            "type": "HEARTBEAT",
            "protocolVersion": 1,
            "timestampMs": 0,
            "heartbeat": True,
            "vlmSummary": "test",
            "latitude": 1.3521,
            "longitude": 103.8198
        }))
        print(await ws.recv())

asyncio.run(main())
PY
```

Replace `<pi-ip>` with:

- the host resolved by Bonjour / mDNS for `_smartcane._tcp`
- fallback: often `172.20.10.2` in phone hotspot mode

Pass criteria:

- Client connects.
- Pi accepts `DISCRETE_CMD`.
- Pi accepts `HEARTBEAT`.
- Client receives `TELEMETRY`.
- Telemetry includes `statusMessage`.

## 7) Pi Network Mode Test

Use the setup guide:

```text
docs/pi-network-setup.md
```

Setup AP onboarding expected:

- Pi advertises `SmartCaneSetup`
- user joins `SmartCaneSetup` manually in iPhone Wi-Fi settings
- app posts hotspot details to `http://192.168.4.1:8081/setup/hotspot`
- Pi switches to hotspot-client mode

Phone hotspot mode expected:

- Pi joins iPhone hotspot
- Pi advertises `_smartcane._tcp` over Bonjour / mDNS
- iOS app discovers the Pi and connects to the resolved WebSocket endpoint
- fallback: iOS app can still try `ws://172.20.10.2:8080/ws`

Check runtime:

```bash
sudo systemctl status smartcane-runtime
journalctl -u smartcane-runtime -n 100
```

Pass criteria:

- Pi runtime is active.
- iOS app changes from `Disconnected` to `Connected`.
- Telemetry status appears in app.

## 7A) Focused Phone App to Pi Test Only

Use this when you want to verify only:

- iPhone app
- Wi-Fi network path
- Pi WebSocket runtime
- Pi camera frame uplink
- Pi telemetry

Do not attach the ESP32 or motors for this test.

Purpose:

- Confirm the phone can connect to Pi over Wi-Fi.
- Confirm `HEARTBEAT`, route commands, and `DEBUG_PING` reach the Pi.
- Confirm Pi telemetry and camera frames reach the app.
- Confirm the FastVLM debug screen shows what the iPhone is receiving.

Setup:

- Pi is powered and on the target network.
- iPhone is on the same network.
- ESP32 may be disconnected.
- Motors remain off.
- Pi camera should be connected if you want to test VLM frame flow.

Start the Pi runtime:

```bash
cd /Users/hanyuxuan/Desktop/REDesign/pi
source .venv/bin/activate
python src/main.py
```

Watch Pi logs in another terminal:

```bash
tail -f /Users/hanyuxuan/Desktop/REDesign/pi/logs/pi_runtime.log
```

Phone app steps:

1. Open the iOS app on the phone.
2. Activate the connection button.
3. Wait for `Connected`.
4. Open the FastVLM screen.
5. Press `Send test ping to Pi`.
6. Confirm the app shows `Last ping` with a round-trip time in milliseconds.
7. Search for a nearby destination from the main screen and select it.
8. Return to the FastVLM screen and inspect:
   - connection logs
   - navigation logs
   - VLM logs
   - latest frame preview, if the Pi camera is active

Expected Pi log events:

- app client connected
- `DEBUG_PING` received
- `DEBUG_PONG` sent
- heartbeat updates
- route command updates
- telemetry broadcasts
- camera frame broadcasts, if camera is enabled

Expected app behavior:

- `Connected` status appears
- `Last ping` shows a non-empty latency value
- connection logs show probe, socket open, ping send, and pong receive
- navigation logs show route request, first instruction, and mapped command
- VLM screen shows:
  - latest frame preview
  - raw model output
  - hazard tags
  - frame age

Acceptable result if ESP32 is disconnected:

- app still connects to Pi
- ping still works
- telemetry still arrives
- Pi status message may mention ESP32 serial link unavailable

Pass criteria:

- Phone connects to Pi over Wi-Fi.
- `Send test ping to Pi` returns a round-trip time.
- App receives telemetry updates from Pi.
- App destination selection produces route logs.
- If Pi camera is enabled, the app receives camera frames and shows them in the FastVLM debug screen.

Fail signals:

- app stays on `Disconnected`
- ping never returns
- Pi log never shows app connection
- app receives no telemetry
- FastVLM screen never shows frame updates even though Pi camera streaming is enabled

## 8) ESP32 Sketch Upload Test

Open Arduino IDE or PlatformIO and upload:

```text
esp32/motor_controller/motor_controller.ino
```

Board:

- ESP32-S3 board matching your hardware

Serial monitor:

```text
115200 baud
```

Expected boot output:

```text
ESP32-S3 smart cane motor controller ready
```

Important:

- `runBootSelfTest` is `false` by default, so motors should not move automatically on power-up.
- To bench-test the original startup ramp, temporarily set `runBootSelfTest = true`, upload, test, then set it back to `false`.

## 9) ESP32 Serial Command Test

With ESP32 connected to your computer and motors safely lifted:

Open Serial Monitor at `115200`.

Send:

```text
FORWARD
```

Expected:

```text
OK FORWARD
```

Then send:

```text
LEFT
RIGHT
STOP
```

Expected:

```text
OK LEFT
OK RIGHT
OK STOP
```

Pass criteria:

- `STOP` turns motor phases off.
- `FORWARD`, `LEFT`, `RIGHT` create distinct motor behavior.
- No movement happens until a command is received.

If directions feel inverted:

- edit `directionsForCommand(...)` in `esp32/motor_controller/motor_controller.ino`
- flip signs for the affected command
- retest one command at a time

## 10) Pi-to-ESP32 Serial Bridge Test

Connect ESP32 to Pi over USB.

On Pi, check detected serial devices:

```bash
ls /dev/ttyUSB* /dev/ttyACM* /dev/serial0 2>/dev/null
```

If needed, set the port:

```bash
export SMARTCANE_ESP32_PORT=/dev/ttyACM0
export SMARTCANE_ESP32_BAUD=115200
```

Run Pi runtime:

```bash
cd /path/to/your/repo/pi
source .venv/bin/activate
python src/main.py
```

Send a WebSocket `DISCRETE_CMD` using the test in section 6.

Pass criteria:

- ESP32 serial monitor shows `OK FORWARD`, `OK LEFT`, `OK RIGHT`, or `OK STOP`.
- Pi telemetry `statusMessage` says something like:

```text
Sent motor command to ESP32: FORWARD
```

If status says serial unavailable:

- verify ESP32 is connected
- verify port path
- verify `pyserial` is installed
- verify Pi user has serial permissions

Common Linux serial permission fix:

```bash
sudo usermod -aG dialout $USER
sudo reboot
```

## 11) Safety Override Test

The Pi safety loop should override app navigation before commands reach ESP32.

Files:

- `pi/src/main.py`
- `pi/src/safety_manager.py`
- `pi/src/motor_controller.py`

Test cases:

- No heartbeat: should force stop after timeout.
- Obstacle under threshold: should send `STOP`.
- Ultrasonic sensor unavailable: should set fault code.
- App sends `FORWARD` while obstacle is too close: ESP32 should receive `STOP`, not `FORWARD`.

Recommended safe test:

1. Lift motors.
2. Start Pi runtime.
3. Start ESP32 serial monitor.
4. Send `FORWARD` from app/WebSocket.
5. Place obstacle close to ultrasonic sensor.
6. Confirm ESP32 receives or remains on `STOP`.

Pass criteria:

- `STOP` takes priority over route command.
- App telemetry shows a fault or obstacle status.

## 12) End-to-End App-to-Motor Test

Only do this after sections 8 to 11 pass.

Setup:

- ESP32 flashed with `motor_controller.ino`
- ESP32 connected to Pi over USB serial
- Pi runtime running
- iPhone hotspot enabled and Pi joined to it
- Motors lifted or cane safely restrained

Steps:

1. Open app on iPhone.
2. Double-tap `Disconnected` to connect.
3. Search a nearby destination.
4. Select destination.
5. Observe ESP32 serial monitor.

Expected:

- iOS sends command to Pi.
- Pi applies safety logic.
- Pi forwards final command to ESP32.
- ESP32 replies `OK <COMMAND>`.
- Motor behavior matches command.

Pass criteria:

- `FORWARD`, `LEFT`, `RIGHT`, and `STOP` all reach ESP32 when expected.
- Obstacle safety can override navigation with `STOP`.
- No unexpected movement on boot or disconnect.

## 13) Integration Testing Guide

Use this section when separate component tests already pass and you want to test
the system as connected parts. Do not skip the earlier component tests.

Integration test order:

1. iOS app to Pi only
2. Pi to ESP32 only
3. iOS app to Pi to ESP32
4. Safety override integration
5. FastVLM to guidance fusion integration
6. Full field rehearsal

### Phase A: iOS App to Pi Only

Purpose:

- Confirm the app can connect to the Pi over Wi-Fi.
- Confirm the Pi receives `DISCRETE_CMD` and `HEARTBEAT`.
- Confirm the app receives `TELEMETRY`.

Setup:

- ESP32 may be disconnected.
- Motors must stay disconnected or safely restrained.
- Pi runtime is running.
- iPhone hotspot is on and the Pi has joined it.

Steps:

1. Start Pi runtime.
2. Open the iOS app.
3. Double-tap `Disconnected`.
4. Wait for `Connected`.
5. Search and select a destination.
6. Watch Pi terminal logs or app status.

Pass criteria:

- App connects to Pi.
- Pi receives heartbeat messages.
- Pi receives route commands.
- App receives telemetry.
- If ESP32 is not connected, status clearly says the ESP32 serial link is unavailable.

Fail signals:

- App remains disconnected.
- Pi never receives heartbeat.
- App connects but no telemetry arrives.
- Pi is not connected to the phone hotspot.

### Phase B: Pi to ESP32 Only

Purpose:

- Confirm the Pi can forward commands to ESP32 over serial without involving the app.

Setup:

- ESP32 is connected to Pi over USB serial.
- ESP32 is flashed with `esp32/motor_controller/motor_controller.ino`.
- Motors are lifted or disconnected from the ground.

Steps:

1. Start ESP32 serial monitor if available.
2. Start Pi runtime.
3. Send a test WebSocket command to Pi using section 6.
4. Send `FORWARD`, `LEFT`, `RIGHT`, and `STOP` one at a time.

Pass criteria:

- ESP32 prints `OK FORWARD`, `OK LEFT`, `OK RIGHT`, and `OK STOP`.
- Pi telemetry status says the command was sent to ESP32.
- `STOP` stops motor phases.

Fail signals:

- Pi status says `No ESP32 serial port found`.
- ESP32 prints nothing.
- ESP32 receives commands but motor direction is wrong.
- ESP32 moves on boot before receiving a command.

### Phase C: iOS App to Pi to ESP32

Purpose:

- Confirm the actual app command path reaches the motor controller.

Setup:

- iPhone app running on physical iPhone.
- Pi runtime running.
- ESP32 connected to Pi.
- Motors lifted or restrained.

Steps:

1. Open iOS app.
2. Connect to cane.
3. Start navigation to a nearby destination.
4. Observe ESP32 serial output.
5. Stop navigation or disconnect cane.

Pass criteria:

- iOS route selection produces a command.
- Pi receives and safety-checks the command.
- ESP32 receives the final command.
- Disconnect or safety stop results in `STOP`.

Fail signals:

- iOS has active navigation but ESP32 receives nothing.
- Pi receives command but ESP32 does not.
- ESP32 receives repeated noisy commands too quickly.
- Motor command continues after app disconnects.

### Phase D: Safety Override Integration

Purpose:

- Confirm obstacle safety takes priority over navigation commands.

Setup:

- Full path connected: iOS app, Pi, ESP32.
- Motors lifted or restrained.
- Ultrasonic sensors connected if available.

Steps:

1. Start navigation from iOS.
2. Confirm ESP32 receives a route command such as `FORWARD`.
3. Place an obstacle within the stop threshold.
4. Confirm Pi overrides with `STOP`.
5. Remove the obstacle.
6. Confirm navigation command resumes only when safe.

Pass criteria:

- Obstacle under threshold forces `STOP`.
- Fault state forces `STOP`.
- App telemetry reflects obstacle or fault status.

Fail signals:

- ESP32 continues receiving `FORWARD` while an obstacle is close.
- App reports safe status while Pi is forcing stop.
- Pi safety state never clears after obstacle is removed.

### Phase E: FastVLM to Guidance Fusion

Purpose:

- Confirm scene understanding can affect guidance decisions.

Setup:

- Pi camera stream active.
- iOS app connected.
- FastVLM screen can display latest scene summary.

Steps:

1. Connect app to Pi.
2. Open FastVLM screen.
3. Confirm latest scene summary updates.
4. Trigger or simulate a hazard tag such as `stairs_ahead`.
5. Confirm `GuidanceFusionManager` sends `STOP`.

Pass criteria:

- Camera frames reach the app.
- `VisionManager` updates scene summary and hazard tags.
- Hazard tags can override route guidance.

Fail signals:

- Camera frames stream but app summary never updates.
- Hazard tags appear but command priority does not change.
- FastVLM output is too slow for real-time guidance.

### Phase F: Full Field Rehearsal

Purpose:

- Confirm the whole system can run in a realistic but controlled setting.

Setup:

- Physical iPhone
- Pi powered from cane battery
- ESP32 powered and connected to Pi
- Motors restrained for first rehearsal, then low-power ground test
- A second person present as safety observer

Steps:

1. Test `STOP`.
2. Connect app to cane.
3. Start navigation to a nearby safe destination.
4. Confirm route command reaches ESP32.
5. Confirm obstacle stop works.
6. Confirm app speech is understandable.
7. Confirm telemetry continues updating.
8. End navigation and disconnect.

Pass criteria:

- No unexpected motor movement.
- `STOP` works from safety and disconnect flows.
- App remains connected long enough for a short navigation test.
- Commands are understandable and match the intended haptic direction after calibration.

Fail signals:

- Any uncontrolled movement.
- Delayed or missing `STOP`.
- Frequent WebSocket disconnects.
- Serial link drops during movement.
- Haptic direction does not match spoken/navigation instruction.

### Integration Test Matrix

| Test | iOS | Pi | ESP32 | Motors | Expected |
| --- | --- | --- | --- | --- | --- |
| App connection | on | on | optional | off | app connects, telemetry received |
| WebSocket command | optional | on | optional | off | Pi receives `DISCRETE_CMD` |
| Serial bridge | optional | on | on | lifted | ESP32 prints `OK <COMMAND>` |
| Full command path | on | on | on | lifted | app command reaches ESP32 |
| Safety stop | on | on | on | lifted | obstacle/fault sends `STOP` |
| FastVLM hazard | on | on | optional | off | hazard tag changes fused command |
| Field rehearsal | on | on | on | restrained, then low-power | stable connection and safe behavior |

## 14) FastVLM Test

Files:

- `ios/SmartCaneApp/Managers/VisionManager.swift`
- `ios/SmartCaneApp/Views/CVModelView.swift`
- `pi/src/camera_streamer.py`

Basic UI test:

1. Open FastVLM screen.
2. Confirm it is scrollable.
3. Confirm status text fits on iPhone screen.

Integration test:

1. Pi streams `CAMERA_FRAME` messages.
2. App receives frames.
3. `VisionManager` updates latest scene summary.
4. `GuidanceFusionManager` can use hazard tags such as `stairs_ahead`.

Pass criteria:

- FastVLM screen does not clip content.
- Latest scene summary updates.
- Hazard tags influence guidance fusion.

## 15) Telemetry Test

Telemetry source:

- `pi/src/comm_server.py`
- `pi/src/main.py`

App display:

- `ios/SmartCaneApp/Views/HomeView.swift`
- `ios/SmartCaneApp/Models/CaneState.swift`

Test:

1. Start Pi runtime.
2. Connect iOS app.
3. Confirm there is no battery card or battery speech because the current hardware cannot report battery level.
4. Confirm telemetry includes motor-unit IMU fields:
   `motorImuAvailable`, `motorImuHeadingDegrees`, `motorImuPitchDegrees`, and
   `motorImuRollDegrees`.
5. Confirm telemetry includes handle/camera IMU fields:
   `handleImuAvailable`, `handleImuHeadingDegrees`, and
   `handleImuGyroZDegreesPerSecond`.

Pass criteria:

- Battery UI and low-battery speech are absent.
- iOS uses motor-unit heading for guidance fallback.
- Handle IMU data is kept separate for future camera deblur/stabilization.

## 16) What To Record During Testing

For each test run, write down:

- date and location
- hardware setup
- hotspot SSID used
- ESP32 serial port
- app destination searched
- command observed on ESP32
- motor-unit IMU telemetry status
- handle IMU telemetry status
- whether obstacle override worked
- any incorrect motor direction
- screenshots or serial logs for failures

Suggested result format:

```text
Test:
Setup:
Expected:
Actual:
Pass/Fail:
Notes:
```

## 17) Known TODOs

- Calibrate ESP32 motor direction signs on real hardware.
- Decide final serial wiring: USB serial vs UART pins.
- Confirm ultrasonic threshold for safe stop.
- Add automated protocol tests for Pi WebSocket messages.
- Add a Pi runtime mock mode for hardware-free integration tests.
