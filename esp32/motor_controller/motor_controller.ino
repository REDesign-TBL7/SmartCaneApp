#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Wire.h>

// ESP32-S3 motor controller for the smart cane.
//
// The Pi remains the primary runtime and talks to this sketch over serial:
// MOVE <vx> <vy> <wz>, LEFT, RIGHT, FORWARD, STOP.
//
// This sketch also exposes a direct Wi-Fi AP + web joystick controller for
// bench testing and fallback motor debugging without the Pi in the loop.

// =========================
// WIFI
// =========================
const char *AP_SSID = "ESP32_OMNI_BOT";
const char *AP_PASS = "12345678";

WebServer server(80);
HardwareSerial piSerial(1);

// =========================
// PIN MAP
// =========================
// Motor 1 = front
#define M1_IN1 4
#define M1_IN2 5
#define M1_IN3 6
#define M1_EN  7

// Motor 2 = rear-left
#define M2_IN1 8
#define M2_IN2 9
#define M2_IN3 10
#define M2_EN  11

// Motor 3 = rear-right
#define M3_IN1 12
#define M3_IN2 13
#define M3_IN3 14
#define M3_EN  15

// Motor-unit IMU I2C
#define IMU_SDA_PIN 38
#define IMU_SCL_PIN 39

// Pi <-> ESP32 GPIO UART
#define PI_UART_RX 42
#define PI_UART_TX 41

// Ultrasonic sensors
#define US1_TRIG 16
#define US1_ECHO 17
#define US2_TRIG 18
#define US2_ECHO 19
#define US3_TRIG 20
#define US3_ECHO 21
#define US4_TRIG 35
#define US4_ECHO 36

// =========================
// TUNING
// =========================
static const unsigned long COMMAND_TIMEOUT_MS = 300;
static const unsigned long STATUS_SAMPLE_INTERVAL_MS = 250;
static const float MAX_DELTA_PER_SEC = 1.8f;
static const float DEADZONE = 0.12f;
static const float MIN_ACTIVE_CMD = 0.20f;
static const uint32_t STEP_DELAY_SLOW = 9000;
static const uint32_t STEP_DELAY_FAST = 2500;
static const bool runBootSelfTest = false;

static const bool INVERT_M1 = false;
static const bool INVERT_M2 = false;
static const bool INVERT_M3 = false;

const char INDEX_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <title>ESP32 Omni Bot</title>
  <style>
    body {
      margin: 0;
      font-family: Arial, sans-serif;
      background: linear-gradient(180deg, #0d1320 0%, #111723 100%);
      color: white;
      overflow-x: hidden;
      touch-action: none;
    }
    .topbar {
      text-align: center;
      padding: 12px;
      font-size: 18px;
      background: #111927;
      border-bottom: 1px solid #2d415f;
    }
    .status {
      text-align: center;
      font-size: 14px;
      color: #b9c7da;
      margin-top: 6px;
      padding: 0 16px;
    }
    .wrap {
      display: flex;
      justify-content: space-around;
      align-items: center;
      min-height: 44vh;
      padding: 10px;
      box-sizing: border-box;
      flex-wrap: wrap;
    }
    .zone-wrap {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 10px;
      padding: 8px;
    }
    .label {
      font-size: 16px;
      color: #ddd;
    }
    .joy {
      width: 42vw;
      height: 42vw;
      max-width: 260px;
      max-height: 260px;
      min-width: 180px;
      min-height: 180px;
      border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #243552 0%, #172334 60%, #111927 100%);
      border: 2px solid #49648d;
      position: relative;
      touch-action: none;
    }
    .stick {
      width: 70px;
      height: 70px;
      border-radius: 50%;
      background: #4da3ff;
      position: absolute;
      left: 50%;
      top: 50%;
      transform: translate(-50%, -50%);
      box-shadow: 0 0 20px rgba(77,163,255,0.5);
    }
    .readout {
      font-size: 14px;
      color: #9fd1ff;
      min-height: 20px;
    }
    .buttons {
      position: fixed;
      left: 0;
      right: 0;
      bottom: 12px;
      display: flex;
      justify-content: center;
      gap: 12px;
      flex-wrap: wrap;
      padding: 0 12px;
    }
    button {
      background: #223146;
      color: white;
      border: 1px solid #4b668f;
      border-radius: 10px;
      padding: 12px 18px;
      font-size: 16px;
    }
    .danger {
      background: #9b1c1c;
      border-color: #c33;
    }
    .controls {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
      padding: 0 14px 96px;
      box-sizing: border-box;
    }
    .card {
      background: rgba(17, 25, 39, 0.92);
      border: 1px solid #334a6c;
      border-radius: 14px;
      padding: 14px;
    }
    .card h3 {
      margin: 0 0 10px;
      font-size: 15px;
      color: #d7e6ff;
    }
    .status-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px 12px;
      font-size: 13px;
    }
    .status-grid div {
      color: #afc2dd;
    }
    .status-grid strong {
      display: block;
      font-size: 12px;
      color: #7e97ba;
      margin-bottom: 3px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .slider-row {
      margin: 10px 0;
    }
    .slider-row label {
      display: flex;
      justify-content: space-between;
      font-size: 13px;
      color: #c7d8ee;
      margin-bottom: 6px;
    }
    input[type="range"] {
      width: 100%;
    }
    .quick-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 8px;
    }
    .quick-grid button {
      padding: 10px 8px;
      font-size: 14px;
    }
    .active-pill {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 8px 10px;
      border-radius: 999px;
      font-size: 13px;
      background: #1a2c43;
      border: 1px solid #3c567a;
      color: #dbe8ff;
    }
    .armed {
      background: #7b1f1f;
      border-color: #c64646;
    }
  </style>
</head>
<body>
  <div class="topbar">ESP32 Demo Backup Controller</div>
  <div class="status" id="status">Connect to Wi-Fi: ESP32_OMNI_BOT → open 192.168.4.1. Arm backup override before using manual control during the demo.</div>

  <div class="wrap">
    <div class="zone-wrap">
      <div class="label">Move</div>
      <div id="moveJoy" class="joy">
        <div class="stick"></div>
      </div>
      <div class="readout" id="moveReadout">vx: 0.00 | vy: 0.00</div>
    </div>

    <div class="zone-wrap">
      <div class="label">Rotate</div>
      <div id="rotJoy" class="joy">
        <div class="stick"></div>
      </div>
      <div class="readout" id="rotReadout">wz: 0.00</div>
    </div>
  </div>

  <div class="controls">
    <div class="card">
      <h3>Backup Mode</h3>
      <button id="overrideButton" onclick="toggleOverride()">Arm backup override</button>
      <div style="margin-top:10px;">
        <span id="overrideState" class="active-pill">Pi commands active</span>
      </div>
      <p style="font-size:13px; color:#9eb4d3; margin:10px 0 0;">
        When armed, web control holds priority until you release it. Use this as the demo fallback if the Pi path becomes unreliable.
      </p>
    </div>

    <div class="card">
      <h3>Speed Tuning</h3>
      <div class="slider-row">
        <label><span>Translate speed</span><span id="translateValue">0.65</span></label>
        <input id="translateScale" type="range" min="0.20" max="1.00" step="0.05" value="0.65" oninput="updateScaleLabels()">
      </div>
      <div class="slider-row">
        <label><span>Rotate speed</span><span id="rotateValue">0.42</span></label>
        <input id="rotateScale" type="range" min="0.15" max="1.00" step="0.05" value="0.42" oninput="updateScaleLabels()">
      </div>
    </div>

    <div class="card">
      <h3>Quick Controls</h3>
      <div class="quick-grid">
        <div></div>
        <button onmousedown="quickMove('forward')" ontouchstart="quickMove('forward')" onmouseup="releaseQuickMove()" onmouseleave="releaseQuickMove()" ontouchend="releaseQuickMove()">Forward</button>
        <div></div>
        <button onmousedown="quickMove('left')" ontouchstart="quickMove('left')" onmouseup="releaseQuickMove()" onmouseleave="releaseQuickMove()" ontouchend="releaseQuickMove()">Left</button>
        <button class="danger" onclick="emergencyStop()">Stop</button>
        <button onmousedown="quickMove('right')" ontouchstart="quickMove('right')" onmouseup="releaseQuickMove()" onmouseleave="releaseQuickMove()" ontouchend="releaseQuickMove()">Right</button>
      </div>
    </div>

    <div class="card">
      <h3>Live Status</h3>
      <div class="status-grid">
        <div><strong>Control source</strong><span id="sourceValue">Unknown</span></div>
        <div><strong>Obstacle</strong><span id="obstacleValue">--</span></div>
        <div><strong>Web vector</strong><span id="webVectorValue">0 / 0 / 0</span></div>
        <div><strong>Serial input</strong><span id="serialValue">Idle</span></div>
        <div><strong>Applied vector</strong><span id="appliedValue">0 / 0 / 0</span></div>
        <div><strong>Wheel mix</strong><span id="wheelValue">0 / 0 / 0</span></div>
      </div>
    </div>
  </div>

  <div class="buttons">
    <button onclick="centerAll()">Center</button>
    <button class="danger" onclick="emergencyStop()">STOP</button>
  </div>

  <script>
    let vx = 0, vy = 0, wz = 0;
    let lastSend = 0;
    let quickMoveActive = false;
    var overrideLatched = false;

    function clamp(v, lo, hi) {
      return Math.max(lo, Math.min(hi, v));
    }

    function setupJoystick(zoneId, mode) {
      const zone = document.getElementById(zoneId);
      const stick = zone.querySelector('.stick');
      const rectInfo = () => zone.getBoundingClientRect();

      let active = false;
      let pointerId = null;

      function setStick(nx, ny) {
        const r = rectInfo();
        const cx = r.width / 2;
        const cy = r.height / 2;
        const maxR = r.width * 0.35;

        let dx = nx - cx;
        let dy = ny - cy;
        const mag = Math.hypot(dx, dy);
        if (mag > maxR) {
          dx = dx / mag * maxR;
          dy = dy / mag * maxR;
        }

        stick.style.left = (cx + dx) + 'px';
        stick.style.top  = (cy + dy) + 'px';

        const x = clamp(dx / maxR, -1, 1);
        const y = clamp(dy / maxR, -1, 1);

        if (mode === 'move') {
          vx = -y;
          vy = -x;
          document.getElementById('moveReadout').textContent =
            `vx: ${vx.toFixed(2)} | vy: ${vy.toFixed(2)}`;
        } else {
          wz = x;
          document.getElementById('rotReadout').textContent =
            `wz: ${wz.toFixed(2)}`;
        }
      }

      function resetStick() {
        stick.style.left = '50%';
        stick.style.top = '50%';
        if (mode === 'move') {
          vx = 0;
          vy = 0;
          document.getElementById('moveReadout').textContent = 'vx: 0.00 | vy: 0.00';
        } else {
          wz = 0;
          document.getElementById('rotReadout').textContent = 'wz: 0.00';
        }
      }

      zone.addEventListener('pointerdown', (e) => {
        active = true;
        pointerId = e.pointerId;
        zone.setPointerCapture(pointerId);
        const r = rectInfo();
        setStick(e.clientX - r.left, e.clientY - r.top);
      });

      zone.addEventListener('pointermove', (e) => {
        if (!active || e.pointerId !== pointerId) return;
        const r = rectInfo();
        if (mode === 'rot') {
          setStick(e.clientX - r.left, r.height / 2);
        } else {
          setStick(e.clientX - r.left, e.clientY - r.top);
        }
      });

      function endPointer(e) {
        if (e.pointerId !== pointerId) return;
        active = false;
        pointerId = null;
        resetStick();
      }

      zone.addEventListener('pointerup', endPointer);
      zone.addEventListener('pointercancel', endPointer);

      return resetStick;
    }

    const resetMove = setupJoystick('moveJoy', 'move');
    const resetRot  = setupJoystick('rotJoy', 'rot');

    function centerAll() {
      resetMove();
      resetRot();
      sendCmd(true);
    }

    function updateScaleLabels() {
      document.getElementById('translateValue').textContent = Number(document.getElementById('translateScale').value).toFixed(2);
      document.getElementById('rotateValue').textContent = Number(document.getElementById('rotateScale').value).toFixed(2);
    }

    function scaledCommand() {
      const translateScale = Number(document.getElementById('translateScale').value);
      const rotateScale = Number(document.getElementById('rotateScale').value);
      return {
        vx: vx * translateScale,
        vy: vy * translateScale,
        wz: wz * rotateScale
      };
    }

    function emergencyStop() {
      vx = 0; vy = 0; wz = 0;
      resetMove();
      resetRot();
      quickMoveActive = false;
      fetch('/stop', { method: 'GET', cache: 'no-store' }).catch(() => {});
    }

    function quickMove(direction) {
      quickMoveActive = true;
      resetMove();
      resetRot();
      if (direction === 'forward') {
        vy = -1;
      } else if (direction === 'left') {
        wz = 1;
      } else if (direction === 'right') {
        wz = -1;
      }
      sendCmd(true);
    }

    function releaseQuickMove() {
      if (!quickMoveActive) return;
      quickMoveActive = false;
      centerAll();
    }

    async function toggleOverride() {
      const target = !overrideLatched;
      try {
        await fetch(`/override?enabled=${target ? '1' : '0'}`, { method: 'GET', cache: 'no-store' });
        overrideLatched = target;
        renderOverrideState();
      } catch (_) {
        document.getElementById('status').textContent = 'Failed to change backup override state';
      }
    }

    function renderOverrideState() {
      const pill = document.getElementById('overrideState');
      const button = document.getElementById('overrideButton');
      if (overrideLatched) {
        pill.textContent = 'Backup override armed';
        pill.classList.add('armed');
        button.textContent = 'Release backup override';
      } else {
        pill.textContent = 'Pi commands active';
        pill.classList.remove('armed');
        button.textContent = 'Arm backup override';
      }
    }

    async function sendCmd(force = false) {
      const now = Date.now();
      if (!force && now - lastSend < 80) return;
      lastSend = now;
      const scaled = scaledCommand();
      try {
        await fetch(`/cmd?vx=${scaled.vx.toFixed(3)}&vy=${scaled.vy.toFixed(3)}&wz=${scaled.wz.toFixed(3)}`, {
          method: 'GET',
          cache: 'no-store'
        });
        document.getElementById('status').textContent =
          `Connected | scaled vx=${scaled.vx.toFixed(2)} vy=${scaled.vy.toFixed(2)} wz=${scaled.wz.toFixed(2)}`;
      } catch (e) {
        document.getElementById('status').textContent = 'Not connected to ESP32';
      }
    }

    async function pollStatus() {
      try {
        const response = await fetch('/status', { cache: 'no-store' });
        const status = await response.json();
        overrideLatched = !!status.webOverrideLatched;
        renderOverrideState();
        document.getElementById('sourceValue').textContent = status.controlSource || 'Unknown';
        document.getElementById('obstacleValue').textContent = status.nearestObstacleCm < 0 ? 'Unavailable' : `${status.nearestObstacleCm.toFixed(0)} cm`;
        document.getElementById('webVectorValue').textContent = `${status.webVx.toFixed(2)} / ${status.webVy.toFixed(2)} / ${status.webWz.toFixed(2)}`;
        document.getElementById('serialValue').textContent = status.serialSummary || 'Idle';
        document.getElementById('appliedValue').textContent = `${status.appliedVx.toFixed(2)} / ${status.appliedVy.toFixed(2)} / ${status.appliedWz.toFixed(2)}`;
        document.getElementById('wheelValue').textContent = `${status.wheel1.toFixed(2)} / ${status.wheel2.toFixed(2)} / ${status.wheel3.toFixed(2)}`;
      } catch (_) {
      }
    }

    updateScaleLabels();
    renderOverrideState();
    setInterval(() => sendCmd(false), 80);
    setInterval(() => pollStatus(), 300);
    pollStatus();
    window.addEventListener('beforeunload', emergencyStop);
  </script>
</body>
</html>
)rawliteral";

enum CaneCommand {
  CMD_STOP,
  CMD_FORWARD,
  CMD_LEFT,
  CMD_RIGHT
};

struct MotorState {
  int in1;
  int in2;
  int in3;
  int en;
  int stepIndex;
  int dir;
  float cmd;
  float out;
  uint32_t stepDelayUs;
  unsigned long lastStepUs;
};

struct UltrasonicPins {
  int trigger;
  int echo;
};

MotorState m1 = {M1_IN1, M1_IN2, M1_IN3, M1_EN, 0, 0, 0.0f, 0.0f, STEP_DELAY_SLOW, 0};
MotorState m2 = {M2_IN1, M2_IN2, M2_IN3, M2_EN, 0, 0, 0.0f, 0.0f, STEP_DELAY_SLOW, 0};
MotorState m3 = {M3_IN1, M3_IN2, M3_IN3, M3_EN, 0, 0, 0.0f, 0.0f, STEP_DELAY_SLOW, 0};

UltrasonicPins ultrasonicSensors[] = {
  { US1_TRIG, US1_ECHO },
  { US2_TRIG, US2_ECHO },
  { US3_TRIG, US3_ECHO },
  { US4_TRIG, US4_ECHO }
};

String serialLine = "";
CaneCommand activeSerialCommand = CMD_STOP;
bool serialMotionActive = false;
float serialVxCmd = 0.0f;
float serialVyCmd = 0.0f;
float serialWzCmd = 0.0f;
bool webOverrideLatched = false;
float webVxCmd = 0.0f;
float webVyCmd = 0.0f;
float webWzCmd = 0.0f;
unsigned long lastWebCommandMs = 0;
unsigned long lastLoopUs = 0;
unsigned long lastMotorImuTelemetryAtMs = 0;
unsigned long lastUltrasonicTelemetryAtMs = 0;
unsigned long lastStatusSampleAtMs = 0;

float sampledVx = 0.0f;
float sampledVy = 0.0f;
float sampledWz = 0.0f;
float sampledW1 = 0.0f;
float sampledW2 = 0.0f;
float sampledW3 = 0.0f;
String sampledControlSource = "IDLE";

bool motorImuAvailable = false;  // TODO: Set true after wiring the real motor-unit IMU.
float motorImuHeadingDegrees = 0.0f;
float motorImuPitchDegrees = 0.0f;
float motorImuRollDegrees = 0.0f;
float nearestObstacleCm = -1.0f;

void debugLog(const String &message) {
  Serial.println(message);
}

void piLinkPrint(const String &message) {
  piSerial.print(message);
  Serial.print(message);
}

void piLinkPrintln(const String &message) {
  piSerial.println(message);
  Serial.println(message);
}

float clampf(float x, float lo, float hi) {
  if (x < lo) return lo;
  if (x > hi) return hi;
  return x;
}

float slew(float target, float current, float maxStep) {
  float delta = target - current;
  if (delta > maxStep) delta = maxStep;
  if (delta < -maxStep) delta = -maxStep;
  return current + delta;
}

float applyDeadzone(float x, float dz) {
  if (fabs(x) < dz) {
    return 0.0f;
  }

  float sign = x >= 0.0f ? 1.0f : -1.0f;
  float scaled = (fabs(x) - dz) / (1.0f - dz);
  return sign * clampf(scaled, 0.0f, 1.0f);
}

void normalize3(float &a, float &b, float &c) {
  float maxMagnitude = fabs(a);
  if (fabs(b) > maxMagnitude) maxMagnitude = fabs(b);
  if (fabs(c) > maxMagnitude) maxMagnitude = fabs(c);

  if (maxMagnitude > 1.0f) {
    a /= maxMagnitude;
    b /= maxMagnitude;
    c /= maxMagnitude;
  }
}

const char *commandName(CaneCommand command) {
  switch (command) {
    case CMD_FORWARD:
      return "FORWARD";
    case CMD_LEFT:
      return "LEFT";
    case CMD_RIGHT:
      return "RIGHT";
    case CMD_STOP:
    default:
      return "STOP";
  }
}

CaneCommand parseCommand(String line) {
  line.trim();
  line.toUpperCase();

  if (line.startsWith("CMD ")) {
    line = line.substring(4);
    line.trim();
  }

  if (line == "FORWARD") return CMD_FORWARD;
  if (line == "LEFT") return CMD_LEFT;
  if (line == "RIGHT") return CMD_RIGHT;
  return CMD_STOP;
}

bool parseMotionCommand(String line, float &vx, float &vy, float &wz) {
  line.trim();
  line.toUpperCase();

  if (line.startsWith("CMD ")) {
    line = line.substring(4);
    line.trim();
  }

  if (!line.startsWith("MOVE ")) {
    return false;
  }

  float parsedVx = 0.0f;
  float parsedVy = 0.0f;
  float parsedWz = 0.0f;
  int matched = sscanf(line.c_str(), "MOVE %f %f %f", &parsedVx, &parsedVy, &parsedWz);
  if (matched != 3) {
    return false;
  }

  vx = applyDeadzone(clampf(parsedVx, -1.0f, 1.0f), DEADZONE);
  vy = applyDeadzone(clampf(parsedVy, -1.0f, 1.0f), DEADZONE);
  wz = applyDeadzone(clampf(parsedWz, -1.0f, 1.0f), DEADZONE);
  return true;
}

void commandToTargets(CaneCommand command, float &vx, float &vy, float &wz) {
  switch (command) {
    case CMD_FORWARD:
      vx = 0.0f;
      vy = -1.0f;
      wz = 0.0f;
      break;
    case CMD_LEFT:
      vx = 0.0f;
      vy = 0.0f;
      wz = 1.0f;
      break;
    case CMD_RIGHT:
      vx = 0.0f;
      vy = 0.0f;
      wz = -1.0f;
      break;
    case CMD_STOP:
    default:
      vx = 0.0f;
      vy = 0.0f;
      wz = 0.0f;
      break;
  }
}

void omniMix(float vx, float vy, float wz, float &a, float &b, float &c) {
  a = -vy + wz;
  b = 0.8660254f * vx + 0.5f * vy + wz;
  c = -0.8660254f * vx + 0.5f * vy + wz;

  normalize3(a, b, c);

  if (INVERT_M1) a = -a;
  if (INVERT_M2) b = -b;
  if (INVERT_M3) c = -c;
}

void motorOff(MotorState &m) {
  digitalWrite(m.in1, LOW);
  digitalWrite(m.in2, LOW);
  digitalWrite(m.in3, LOW);
  m.dir = 0;
}

void allOff() {
  motorOff(m1);
  motorOff(m2);
  motorOff(m3);
}

void applyStep(MotorState &m, int step) {
  switch (step) {
    case 0:
      digitalWrite(m.in1, HIGH);
      digitalWrite(m.in2, LOW);
      digitalWrite(m.in3, LOW);
      break;
    case 1:
      digitalWrite(m.in1, HIGH);
      digitalWrite(m.in2, HIGH);
      digitalWrite(m.in3, LOW);
      break;
    case 2:
      digitalWrite(m.in1, LOW);
      digitalWrite(m.in2, HIGH);
      digitalWrite(m.in3, LOW);
      break;
    case 3:
      digitalWrite(m.in1, LOW);
      digitalWrite(m.in2, HIGH);
      digitalWrite(m.in3, HIGH);
      break;
    case 4:
      digitalWrite(m.in1, LOW);
      digitalWrite(m.in2, LOW);
      digitalWrite(m.in3, HIGH);
      break;
    case 5:
      digitalWrite(m.in1, HIGH);
      digitalWrite(m.in2, LOW);
      digitalWrite(m.in3, HIGH);
      break;
  }
}

void setMotorCommand(MotorState &m, float x) {
  x = clampf(x, -1.0f, 1.0f);

  if (fabs(x) < 0.001f) {
    m.cmd = 0.0f;
    return;
  }

  float sign = x >= 0.0f ? 1.0f : -1.0f;
  float magnitude = fabs(x);
  if (magnitude < MIN_ACTIVE_CMD) magnitude = MIN_ACTIVE_CMD;
  m.cmd = sign * magnitude;
}

void updateMotorOutput(MotorState &m) {
  if (fabs(m.out) < 0.01f) {
    motorOff(m);
    return;
  }

  m.dir = m.out > 0.0f ? 1 : -1;
  float magnitude = fabs(m.out);
  float t = clampf(magnitude, 0.0f, 1.0f);
  m.stepDelayUs = (uint32_t)(STEP_DELAY_SLOW - t * (STEP_DELAY_SLOW - STEP_DELAY_FAST));
}

void serviceMotor(MotorState &m, unsigned long nowUs) {
  if (fabs(m.out) < 0.01f) {
    return;
  }

  if ((uint32_t)(nowUs - m.lastStepUs) < m.stepDelayUs) {
    return;
  }

  m.lastStepUs = nowUs;
  if (m.dir > 0) {
    m.stepIndex = (m.stepIndex + 1) % 6;
  } else {
    m.stepIndex = (m.stepIndex + 5) % 6;
  }
  applyStep(m, m.stepIndex);
}

void stopWebTargets() {
  webVxCmd = 0.0f;
  webVyCmd = 0.0f;
  webWzCmd = 0.0f;
}

String currentControlSourceLabel() {
  unsigned long nowMs = millis();
  if (webOverrideLatched) {
    return "WEB_OVERRIDE";
  }
  if (nowMs - lastWebCommandMs <= COMMAND_TIMEOUT_MS) {
    return "WEB_ACTIVE";
  }
  if (serialMotionActive) {
    return "PI_MOVE";
  }
  if (activeSerialCommand != CMD_STOP) {
    return String("PI_") + commandName(activeSerialCommand);
  }
  return "IDLE";
}

String serialSummary() {
  if (serialMotionActive) {
    return String("MOVE ")
      + String(serialVxCmd, 2) + " "
      + String(serialVyCmd, 2) + " "
      + String(serialWzCmd, 2);
  }
  return commandName(activeSerialCommand);
}

void sampleAppliedMotion(float vx, float vy, float wz, float w1, float w2, float w3) {
  unsigned long nowMs = millis();
  if (nowMs - lastStatusSampleAtMs < STATUS_SAMPLE_INTERVAL_MS) {
    return;
  }

  lastStatusSampleAtMs = nowMs;
  sampledVx = vx;
  sampledVy = vy;
  sampledWz = wz;
  sampledW1 = w1;
  sampledW2 = w2;
  sampledW3 = w3;
  sampledControlSource = currentControlSourceLabel();
}

void updateMotorUnitImu() {
  // TODO: Read the ESP32-side motor-unit IMU here.
  //
  // This IMU should describe the motor/tip unit orientation used for haptic
  // motor control. Do not use the Pi handle IMU here; that one is reserved for
  // camera deblur/stabilization.
}

void sendMotorImuTelemetry() {
  piSerial.print("MOTOR_IMU ");
  piSerial.print(motorImuAvailable ? 1 : 0);
  piSerial.print(" ");
  piSerial.print(motorImuHeadingDegrees, 2);
  piSerial.print(" ");
  piSerial.print(motorImuPitchDegrees, 2);
  piSerial.print(" ");
  piSerial.println(motorImuRollDegrees, 2);
}

float readSensorDistanceCm(UltrasonicPins sensor) {
  if (sensor.trigger < 0 || sensor.echo < 0) {
    return -1.0f;
  }

  digitalWrite(sensor.trigger, LOW);
  delayMicroseconds(2);
  digitalWrite(sensor.trigger, HIGH);
  delayMicroseconds(10);
  digitalWrite(sensor.trigger, LOW);

  unsigned long durationMicros = pulseIn(sensor.echo, HIGH, 30000);
  if (durationMicros == 0) {
    return -1.0f;
  }

  return (durationMicros * 0.0343f) / 2.0f;
}

void updateUltrasonicSensors() {
  float bestDistance = -1.0f;
  for (UltrasonicPins sensor : ultrasonicSensors) {
    float candidate = readSensorDistanceCm(sensor);
    if (candidate <= 0.0f) {
      continue;
    }
    if (bestDistance < 0.0f || candidate < bestDistance) {
      bestDistance = candidate;
    }
  }
  nearestObstacleCm = bestDistance;
}

void sendUltrasonicTelemetry() {
  piSerial.print("ULTRASONIC ");
  piSerial.println(nearestObstacleCm, 2);
}

void handleSerialInput() {
  while (piSerial.available() > 0) {
    char incoming = piSerial.read();
    if (incoming == '\n' || incoming == '\r') {
      if (serialLine.length() == 0) {
        continue;
      }

      float vx = 0.0f;
      float vy = 0.0f;
      float wz = 0.0f;
      if (parseMotionCommand(serialLine, vx, vy, wz)) {
        serialMotionActive = true;
        serialVxCmd = vx;
        serialVyCmd = vy;
        serialWzCmd = wz;
        activeSerialCommand = CMD_STOP;
        piLinkPrintln("OK MOVE");
      } else {
        serialMotionActive = false;
        activeSerialCommand = parseCommand(serialLine);
        if (activeSerialCommand == CMD_STOP) {
          serialVxCmd = 0.0f;
          serialVyCmd = 0.0f;
          serialWzCmd = 0.0f;
        }
        piLinkPrint("OK ");
        piLinkPrintln(commandName(activeSerialCommand));
      }
      serialLine = "";
    } else {
      serialLine += incoming;
    }
  }
}

void handleRoot() {
  server.send_P(200, "text/html", INDEX_HTML);
}

void handleCmd() {
  if (server.hasArg("vx")) webVxCmd = clampf(server.arg("vx").toFloat(), -1.0f, 1.0f);
  if (server.hasArg("vy")) webVyCmd = clampf(server.arg("vy").toFloat(), -1.0f, 1.0f);
  if (server.hasArg("wz")) webWzCmd = clampf(server.arg("wz").toFloat(), -1.0f, 1.0f);

  webVxCmd = applyDeadzone(webVxCmd, DEADZONE);
  webVyCmd = applyDeadzone(webVyCmd, DEADZONE);
  webWzCmd = applyDeadzone(webWzCmd, DEADZONE);
  lastWebCommandMs = millis();

  server.send(200, "text/plain", "OK");
}

void handleOverride() {
  if (server.hasArg("enabled")) {
    webOverrideLatched = server.arg("enabled") == "1";
    if (!webOverrideLatched) {
      stopWebTargets();
    }
  }

  server.send(200, "text/plain", webOverrideLatched ? "OVERRIDE_ON" : "OVERRIDE_OFF");
}

void handleStatus() {
  String payload = "{";
  payload += "\"controlSource\":\"" + sampledControlSource + "\",";
  payload += "\"webOverrideLatched\":" + String(webOverrideLatched ? "true" : "false") + ",";
  payload += "\"nearestObstacleCm\":" + String(nearestObstacleCm, 2) + ",";
  payload += "\"webVx\":" + String(webVxCmd, 3) + ",";
  payload += "\"webVy\":" + String(webVyCmd, 3) + ",";
  payload += "\"webWz\":" + String(webWzCmd, 3) + ",";
  payload += "\"appliedVx\":" + String(sampledVx, 3) + ",";
  payload += "\"appliedVy\":" + String(sampledVy, 3) + ",";
  payload += "\"appliedWz\":" + String(sampledWz, 3) + ",";
  payload += "\"wheel1\":" + String(sampledW1, 3) + ",";
  payload += "\"wheel2\":" + String(sampledW2, 3) + ",";
  payload += "\"wheel3\":" + String(sampledW3, 3) + ",";
  payload += "\"serialSummary\":\"" + serialSummary() + "\"";
  payload += "}";
  server.send(200, "application/json", payload);
}

void handleStop() {
  stopWebTargets();
  lastWebCommandMs = millis();
  server.send(200, "text/plain", "STOPPED");
}

void startWiFiAP() {
  WiFi.mode(WIFI_AP);
  bool ok = WiFi.softAP(AP_SSID, AP_PASS);
  IPAddress ip = WiFi.softAPIP();

  Serial.println();
  if (ok) {
    debugLog("Wi-Fi AP started");
    debugLog(String("SSID: ") + AP_SSID);
    debugLog(String("PASS: ") + AP_PASS);
    debugLog(String("Open browser at: http://") + ip.toString());
  } else {
    debugLog("Failed to start Wi-Fi AP");
  }
}

void setupWeb() {
  server.on("/", HTTP_GET, handleRoot);
  server.on("/cmd", HTTP_GET, handleCmd);
  server.on("/override", HTTP_GET, handleOverride);
  server.on("/status", HTTP_GET, handleStatus);
  server.on("/stop", HTTP_GET, handleStop);
  server.begin();
  debugLog("Web server started");
}

void setupMotorPins(MotorState &m) {
  pinMode(m.in1, OUTPUT);
  pinMode(m.in2, OUTPUT);
  pinMode(m.in3, OUTPUT);
  pinMode(m.en, OUTPUT);
  digitalWrite(m.en, HIGH);
  motorOff(m);
}

void setupUltrasonicPins() {
  for (UltrasonicPins sensor : ultrasonicSensors) {
    if (sensor.trigger < 0 || sensor.echo < 0) {
      continue;
    }

    pinMode(sensor.trigger, OUTPUT);
    pinMode(sensor.echo, INPUT);
    digitalWrite(sensor.trigger, LOW);
  }
}

void runSelfTest() {
  unsigned long startAt = millis();
  webVyCmd = -1.0f;
  lastWebCommandMs = startAt;
  while (millis() - startAt < 1200) {
    server.handleClient();
    handleSerialInput();
  }
  stopWebTargets();
}

void resolveControlTargets(float &vx, float &vy, float &wz) {
  unsigned long nowMs = millis();
  if (webOverrideLatched) {
    vx = webVxCmd;
    vy = webVyCmd;
    wz = webWzCmd;
    return;
  }
  if (nowMs - lastWebCommandMs <= COMMAND_TIMEOUT_MS) {
    vx = webVxCmd;
    vy = webVyCmd;
    wz = webWzCmd;
    return;
  }

  stopWebTargets();
  if (serialMotionActive) {
    vx = serialVxCmd;
    vy = serialVyCmd;
    wz = serialWzCmd;
    return;
  }
  commandToTargets(activeSerialCommand, vx, vy, wz);
}

void setup() {
  Serial.begin(115200);
  piSerial.begin(115200, SERIAL_8N1, PI_UART_RX, PI_UART_TX);
  Wire.begin(IMU_SDA_PIN, IMU_SCL_PIN);
  debugLog("ESP32-S3 smart cane motor controller ready");
  debugLog(String("Pi UART RX pin: ") + PI_UART_RX);
  debugLog(String("Pi UART TX pin: ") + PI_UART_TX);
  debugLog(String("IMU SDA pin: ") + IMU_SDA_PIN);
  debugLog(String("IMU SCL pin: ") + IMU_SCL_PIN);

  setupMotorPins(m1);
  setupMotorPins(m2);
  setupMotorPins(m3);
  setupUltrasonicPins();
  allOff();

  startWiFiAP();
  setupWeb();

  lastLoopUs = micros();
  if (runBootSelfTest) {
    runSelfTest();
  }
}

void loop() {
  server.handleClient();
  handleSerialInput();
  updateMotorUnitImu();
  updateUltrasonicSensors();

  unsigned long nowMs = millis();
  if (nowMs - lastMotorImuTelemetryAtMs >= 200) {
    lastMotorImuTelemetryAtMs = nowMs;
    sendMotorImuTelemetry();
  }
  if (nowMs - lastUltrasonicTelemetryAtMs >= 120) {
    lastUltrasonicTelemetryAtMs = nowMs;
    sendUltrasonicTelemetry();
  }

  unsigned long nowUs = micros();
  float dt = (nowUs - lastLoopUs) * 1e-6f;
  lastLoopUs = nowUs;
  dt = clampf(dt, 0.0005f, 0.05f);

  float vx = 0.0f;
  float vy = 0.0f;
  float wz = 0.0f;
  resolveControlTargets(vx, vy, wz);

  float w1, w2, w3;
  omniMix(vx, vy, wz, w1, w2, w3);
  sampleAppliedMotion(vx, vy, wz, w1, w2, w3);

  setMotorCommand(m1, w1);
  setMotorCommand(m2, w2);
  setMotorCommand(m3, w3);

  float step = MAX_DELTA_PER_SEC * dt;
  m1.out = slew(m1.cmd, m1.out, step);
  m2.out = slew(m2.cmd, m2.out, step);
  m3.out = slew(m3.cmd, m3.out, step);

  updateMotorOutput(m1);
  updateMotorOutput(m2);
  updateMotorOutput(m3);

  serviceMotor(m1, nowUs);
  serviceMotor(m2, nowUs);
  serviceMotor(m3, nowUs);
}
