#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Wire.h>
#include <Update.h>

// ESP32-S3 motor controller for the smart cane.
//
// The core motor-control behavior intentionally follows the standalone
// reference joystick sketch. The Pi serial link and telemetry are layered on
// top of that same control loop instead of using a separate motor path.

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
static const float MAX_DELTA_PER_SEC = 1.8f;
static const float DEADZONE = 0.12f;
static const float MIN_ACTIVE_CMD = 0.20f;
static const uint32_t STEP_DELAY_SLOW = 9000;
static const uint32_t STEP_DELAY_FAST = 2500;
static const unsigned long ULTRASONIC_POLL_INTERVAL_MS = 35;
static const unsigned long ULTRASONIC_SAMPLE_STALE_MS = 250;
static const unsigned long ULTRASONIC_ECHO_TIMEOUT_US = 18000;
static const float OBSTACLE_TRIGGER_CM = 5.0f;
static const float OBSTACLE_CLEAR_CM = 8.0f;
static const unsigned long FRONT_REVERSE_DURATION_MS = 250;
static const unsigned long FRONT_SIDESTEP_DURATION_MS = 1200;
static const unsigned long SIDE_SIDESTEP_DURATION_MS = 700;
static const unsigned long AVOIDANCE_COOLDOWN_MS = 400;
static const unsigned long AVOIDANCE_STARTUP_SETTLE_MS = 1500;
static const uint8_t AVOIDANCE_CONFIRMATION_COUNT = 2;
static const float AVOIDANCE_REVERSE_SPEED = 0.70f;
static const float AVOIDANCE_SIDESTEP_SPEED = 0.80f;
static const uint8_t MPU6050_ADDR = 0x68;
static const uint8_t REG_PWR_MGMT_1 = 0x6B;
static const uint8_t REG_SMPLRT_DIV = 0x19;
static const uint8_t REG_CONFIG = 0x1A;
static const uint8_t REG_GYRO_CONFIG = 0x1B;
static const uint8_t REG_ACCEL_CONFIG = 0x1C;
static const uint8_t REG_ACCEL_XOUT_H = 0x3B;
static const float MPU6050_ACCEL_LSB_PER_G = 16384.0f;
static const float MPU6050_GYRO_LSB_PER_DPS = 131.0f;
static const float MOTOR_IMU_COMPLEMENTARY_ALPHA = 0.96f;

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
      background: #111;
      color: white;
      overflow: hidden;
      touch-action: none;
    }
    .topbar {
      text-align: center;
      padding: 12px;
      font-size: 18px;
      background: #1b1b1b;
      border-bottom: 1px solid #333;
    }
    .status {
      text-align: center;
      font-size: 14px;
      color: #aaa;
      margin-top: 6px;
    }
    .wrap {
      display: flex;
      justify-content: space-around;
      align-items: center;
      height: calc(100vh - 70px);
      padding: 10px;
      box-sizing: border-box;
    }
    .zone-wrap {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 10px;
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
      background: #222;
      border: 2px solid #555;
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
    }
    button {
      background: #2d2d2d;
      color: white;
      border: 1px solid #555;
      border-radius: 10px;
      padding: 12px 18px;
      font-size: 16px;
    }
    .danger {
      background: #9b1c1c;
      border-color: #c33;
    }
    .linkbar {
      position: fixed;
      top: 12px;
      right: 12px;
    }
    .linkbar a {
      color: #9fd1ff;
      text-decoration: none;
      font-size: 14px;
      background: rgba(27,27,27,0.95);
      border: 1px solid #444;
      border-radius: 999px;
      padding: 8px 12px;
      display: inline-block;
    }
  </style>
</head>
<body>
  <div class="linkbar">
    <a href="/update">Firmware Update</a>
  </div>
  <div class="topbar">ESP32 Omni Bot Controller</div>
  <div class="status" id="status">Connect to Wi-Fi: ESP32_OMNI_BOT → open 192.168.4.1</div>

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

  <div class="buttons">
    <button onclick="centerAll()">Center</button>
    <button class="danger" onclick="emergencyStop()">STOP</button>
  </div>

  <script>
    let vx = 0, vy = 0, wz = 0;
    let lastSend = 0;

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

    function emergencyStop() {
      vx = 0; vy = 0; wz = 0;
      resetMove();
      resetRot();
      fetch('/stop', { method: 'GET', cache: 'no-store' }).catch(() => {});
    }

    async function sendCmd(force = false) {
      const now = Date.now();
      if (!force && now - lastSend < 80) return;
      lastSend = now;
      try {
        await fetch(`/cmd?vx=${vx.toFixed(3)}&vy=${vy.toFixed(3)}&wz=${wz.toFixed(3)}`, {
          method: 'GET',
          cache: 'no-store'
        });
        document.getElementById('status').textContent =
          `Connected | vx=${vx.toFixed(2)} vy=${vy.toFixed(2)} wz=${wz.toFixed(2)}`;
      } catch (e) {
        document.getElementById('status').textContent = 'Not connected to ESP32';
      }
    }
    setInterval(() => sendCmd(false), 80);
    window.addEventListener('beforeunload', emergencyStop);
  </script>
</body>
</html>
)rawliteral";

const char UPDATE_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ESP32 OTA Update</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      background: #111;
      color: white;
      padding: 24px;
    }
    .card {
      max-width: 520px;
      margin: 0 auto;
      background: #1b1b1b;
      border: 1px solid #333;
      border-radius: 14px;
      padding: 20px;
    }
    input, button {
      width: 100%;
      margin-top: 12px;
      padding: 12px;
      border-radius: 10px;
      border: 1px solid #555;
      background: #222;
      color: white;
      box-sizing: border-box;
    }
    button {
      background: #2f6fed;
      border-color: #2f6fed;
      font-weight: 600;
    }
    a {
      color: #9fd1ff;
    }
  </style>
</head>
<body>
  <div class="card">
    <h2>ESP32 Wi-Fi Firmware Update</h2>
    <p>Connect to <strong>ESP32_OMNI_BOT</strong>, then upload the compiled firmware binary.</p>
    <form method="POST" action="/update" enctype="multipart/form-data">
      <input type="file" name="firmware" accept=".bin" required>
      <button type="submit">Upload Firmware</button>
    </form>
    <p><a href="/">Back to controller</a></p>
  </div>
</body>
</html>
)rawliteral";

enum CaneCommand {
  CMD_STOP,
  CMD_FORWARD,
  CMD_LEFT,
  CMD_RIGHT
};

enum CommandSource {
  SOURCE_NONE,
  SOURCE_WEB,
  SOURCE_PI_SERIAL
};

enum AvoidanceMode {
  AVOIDANCE_NONE,
  AVOIDANCE_REVERSE,
  AVOIDANCE_SIDESTEP_LEFT,
  AVOIDANCE_SIDESTEP_RIGHT,
  AVOIDANCE_COOLDOWN
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
static const size_t ULTRASONIC_SENSOR_COUNT = sizeof(ultrasonicSensors) / sizeof(ultrasonicSensors[0]);
static const size_t RIGHT_SENSOR_INDEX = 0;
static const size_t LEGACY_FRONT_SENSOR_INDEX = 1;
static const size_t LEFT_SENSOR_INDEX = 2;
static const size_t FRONT_SENSOR_INDEX = 3;

String serialLine = "";
String usbSerialLine = "";
float vx_cmd = 0.0f;
float vy_cmd = 0.0f;
float wz_cmd = 0.0f;
unsigned long lastCommandMs = 0;
unsigned long lastWebCommandMs = 0;
unsigned long lastLoopUs = 0;
unsigned long lastMotorImuTelemetryAtMs = 0;
unsigned long lastUltrasonicTelemetryAtMs = 0;
unsigned long lastUltrasonicPollAtMs = 0;
size_t nextUltrasonicSensorIndex = 0;
unsigned long lastMotorImuReadUs = 0;

bool motorImuAvailable = false;
float motorImuHeadingDegrees = 0.0f;
float motorImuPitchDegrees = 0.0f;
float motorImuRollDegrees = 0.0f;
float motorImuGyroBiasX = 0.0f;
float motorImuGyroBiasY = 0.0f;
float motorImuGyroBiasZ = 0.0f;
float nearestObstacleCm = -1.0f;
float ultrasonicDistances[ULTRASONIC_SENSOR_COUNT] = { -1.0f, -1.0f, -1.0f, -1.0f };
unsigned long ultrasonicSampleAtMs[ULTRASONIC_SENSOR_COUNT] = { 0, 0, 0, 0 };
CommandSource activeCommandSource = SOURCE_NONE;
AvoidanceMode activeAvoidanceMode = AVOIDANCE_NONE;
unsigned long avoidanceModeStartedAtMs = 0;
unsigned long avoidanceSidestepDurationMs = FRONT_SIDESTEP_DURATION_MS;
float bestRightDistanceDuringReverseCm = -1.0f;
float bestLeftDistanceDuringReverseCm = -1.0f;
uint8_t frontObstacleConfirmCount = 0;
uint8_t rightObstacleConfirmCount = 0;
uint8_t leftObstacleConfirmCount = 0;
bool frontObstacleLatched = false;

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

const char *avoidanceModeName(AvoidanceMode mode) {
  switch (mode) {
    case AVOIDANCE_REVERSE:
      return "REVERSE";
    case AVOIDANCE_SIDESTEP_LEFT:
      return "SIDESTEP_LEFT";
    case AVOIDANCE_SIDESTEP_RIGHT:
      return "SIDESTEP_RIGHT";
    case AVOIDANCE_COOLDOWN:
      return "COOLDOWN";
    case AVOIDANCE_NONE:
    default:
      return "NONE";
  }
}

float slew(float target, float current, float maxStep) {
  float delta = target - current;
  if (delta > maxStep) delta = maxStep;
  if (delta < -maxStep) delta = -maxStep;
  return current + delta;
}

float applyDeadzone(float x, float dz) {
  if (fabs(x) < dz) return 0.0f;
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
      // Physical motor wiring is mirrored on the current build.
      vx = -1.0f;
      vy = 0.0f;
      wz = 0.0f;
      break;
    case CMD_LEFT:
      vx = 0.0f;
      vy = -1.0f;
      wz = 0.0f;
      break;
    case CMD_RIGHT:
      vx = 0.0f;
      vy = 1.0f;
      wz = 0.0f;
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

void stopTargets() {
  vx_cmd = 0.0f;
  vy_cmd = 0.0f;
  wz_cmd = 0.0f;
  m1.cmd = 0.0f;
  m2.cmd = 0.0f;
  m3.cmd = 0.0f;
  activeCommandSource = SOURCE_NONE;
}

bool webControlActive() {
  return (millis() - lastWebCommandMs) <= COMMAND_TIMEOUT_MS;
}

void printStatus() {
  static unsigned long lastPrint = 0;
  if (millis() - lastPrint < 250) return;
  lastPrint = millis();

  Serial.print("cmd ");
  Serial.print(vx_cmd, 2); Serial.print(", ");
  Serial.print(vy_cmd, 2); Serial.print(", ");
  Serial.print(wz_cmd, 2);
  Serial.print(" | wheels ");
  Serial.print(m1.out, 2); Serial.print(", ");
  Serial.print(m2.out, 2); Serial.print(", ");
  Serial.print(m3.out, 2);
  Serial.print(" | avoid ");
  Serial.print(avoidanceModeName(activeAvoidanceMode));
  Serial.print(" | us ");
  Serial.print(ultrasonicDistances[RIGHT_SENSOR_INDEX], 1);
  Serial.print(", ");
  Serial.print(ultrasonicDistances[LEGACY_FRONT_SENSOR_INDEX], 1);
  Serial.print(", ");
  Serial.print(ultrasonicDistances[LEFT_SENSOR_INDEX], 1);
  Serial.print(", ");
  Serial.println(ultrasonicDistances[FRONT_SENSOR_INDEX], 1);
}

bool imuWriteRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool imuReadBytes(uint8_t reg, uint8_t count, uint8_t *buffer) {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  uint8_t received = Wire.requestFrom((int)MPU6050_ADDR, (int)count, (int)true);
  if (received != count) {
    return false;
  }

  for (uint8_t i = 0; i < count; i++) {
    buffer[i] = Wire.read();
  }
  return true;
}

int16_t imuWordAt(const uint8_t *buffer, uint8_t offset) {
  return (int16_t)((buffer[offset] << 8) | buffer[offset + 1]);
}

void calibrateMotorUnitImuBias(size_t samples = 160) {
  float sumX = 0.0f;
  float sumY = 0.0f;
  float sumZ = 0.0f;
  uint8_t raw[14];
  size_t validSamples = 0;

  for (size_t i = 0; i < samples; i++) {
    if (!imuReadBytes(REG_ACCEL_XOUT_H, sizeof(raw), raw)) {
      delay(5);
      continue;
    }

    sumX += (float)imuWordAt(raw, 8);
    sumY += (float)imuWordAt(raw, 10);
    sumZ += (float)imuWordAt(raw, 12);
    validSamples++;
    delay(4);
  }

  if (validSamples == 0) {
    motorImuAvailable = false;
    return;
  }

  motorImuGyroBiasX = sumX / (float)validSamples;
  motorImuGyroBiasY = sumY / (float)validSamples;
  motorImuGyroBiasZ = sumZ / (float)validSamples;
}

void setupMotorUnitImu() {
  motorImuAvailable = false;

  if (!imuWriteRegister(REG_PWR_MGMT_1, 0x00)) {
    debugLog("MPU6050 not detected on I2C");
    return;
  }

  delay(100);
  imuWriteRegister(REG_SMPLRT_DIV, 0x07);
  imuWriteRegister(REG_CONFIG, 0x03);
  imuWriteRegister(REG_GYRO_CONFIG, 0x00);
  imuWriteRegister(REG_ACCEL_CONFIG, 0x00);

  calibrateMotorUnitImuBias();
  motorImuHeadingDegrees = 0.0f;
  motorImuPitchDegrees = 0.0f;
  motorImuRollDegrees = 0.0f;
  lastMotorImuReadUs = micros();
  motorImuAvailable = true;
  debugLog("MPU6050 motor-unit IMU ready");
}

void updateMotorUnitImu() {
  if (!motorImuAvailable) {
    return;
  }

  uint8_t raw[14];
  if (!imuReadBytes(REG_ACCEL_XOUT_H, sizeof(raw), raw)) {
    motorImuAvailable = false;
    debugLog("MPU6050 read failed; disabling motor-unit IMU");
    return;
  }

  int16_t accelXRaw = imuWordAt(raw, 0);
  int16_t accelYRaw = imuWordAt(raw, 2);
  int16_t accelZRaw = imuWordAt(raw, 4);
  int16_t gyroXRaw = imuWordAt(raw, 8);
  int16_t gyroYRaw = imuWordAt(raw, 10);
  int16_t gyroZRaw = imuWordAt(raw, 12);

  float accelX = accelXRaw / MPU6050_ACCEL_LSB_PER_G;
  float accelY = accelYRaw / MPU6050_ACCEL_LSB_PER_G;
  float accelZ = accelZRaw / MPU6050_ACCEL_LSB_PER_G;

  float gyroX = (gyroXRaw - motorImuGyroBiasX) / MPU6050_GYRO_LSB_PER_DPS;
  float gyroY = (gyroYRaw - motorImuGyroBiasY) / MPU6050_GYRO_LSB_PER_DPS;
  float gyroZ = (gyroZRaw - motorImuGyroBiasZ) / MPU6050_GYRO_LSB_PER_DPS;

  unsigned long nowUs = micros();
  float dt = lastMotorImuReadUs == 0 ? 0.01f : (nowUs - lastMotorImuReadUs) * 1e-6f;
  lastMotorImuReadUs = nowUs;
  dt = clampf(dt, 0.001f, 0.05f);

  float accelRoll = atan2f(accelY, accelZ) * 180.0f / PI;
  float accelPitch = atan2f(-accelX, sqrtf(accelY * accelY + accelZ * accelZ)) * 180.0f / PI;

  motorImuRollDegrees =
    MOTOR_IMU_COMPLEMENTARY_ALPHA * (motorImuRollDegrees + gyroX * dt)
    + (1.0f - MOTOR_IMU_COMPLEMENTARY_ALPHA) * accelRoll;
  motorImuPitchDegrees =
    MOTOR_IMU_COMPLEMENTARY_ALPHA * (motorImuPitchDegrees + gyroY * dt)
    + (1.0f - MOTOR_IMU_COMPLEMENTARY_ALPHA) * accelPitch;

  motorImuHeadingDegrees += gyroZ * dt;
  while (motorImuHeadingDegrees >= 360.0f) motorImuHeadingDegrees -= 360.0f;
  while (motorImuHeadingDegrees < 0.0f) motorImuHeadingDegrees += 360.0f;
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

  unsigned long durationMicros = pulseIn(sensor.echo, HIGH, ULTRASONIC_ECHO_TIMEOUT_US);
  if (durationMicros == 0) {
    return -1.0f;
  }

  return (durationMicros * 0.0343f) / 2.0f;
}

void recomputeNearestObstacle(unsigned long nowMs) {
  float bestDistance = -1.0f;
  for (size_t i = 0; i < ULTRASONIC_SENSOR_COUNT; i++) {
    if (ultrasonicSampleAtMs[i] == 0 || (nowMs - ultrasonicSampleAtMs[i]) > ULTRASONIC_SAMPLE_STALE_MS) {
      ultrasonicDistances[i] = -1.0f;
      continue;
    }

    float candidate = ultrasonicDistances[i];
    if (candidate <= 0.0f) {
      continue;
    }

    if (bestDistance < 0.0f || candidate < bestDistance) {
      bestDistance = candidate;
    }
  }

  nearestObstacleCm = bestDistance;
}

float freshUltrasonicDistanceCm(size_t sensorIndex, unsigned long nowMs) {
  if (sensorIndex >= ULTRASONIC_SENSOR_COUNT) {
    return -1.0f;
  }

  if (ultrasonicSampleAtMs[sensorIndex] == 0 || (nowMs - ultrasonicSampleAtMs[sensorIndex]) > ULTRASONIC_SAMPLE_STALE_MS) {
    return -1.0f;
  }

  float candidate = ultrasonicDistances[sensorIndex];
  return candidate > 0.0f ? candidate : -1.0f;
}

void setAvoidanceMode(AvoidanceMode mode, unsigned long nowMs, const String &reason) {
  if (activeAvoidanceMode != mode) {
    debugLog(String("Avoidance -> ") + avoidanceModeName(mode) + " (" + reason + ")");
  }
  activeAvoidanceMode = mode;
  avoidanceModeStartedAtMs = nowMs;
}

void resetAvoidanceConfirmCounters() {
  frontObstacleConfirmCount = 0;
  rightObstacleConfirmCount = 0;
  leftObstacleConfirmCount = 0;
}

uint8_t bumpConfirmCounter(uint8_t currentValue) {
  if (currentValue >= AVOIDANCE_CONFIRMATION_COUNT) {
    return AVOIDANCE_CONFIRMATION_COUNT;
  }
  return currentValue + 1;
}

void beginFrontAvoidance(unsigned long nowMs) {
  bestRightDistanceDuringReverseCm = -1.0f;
  bestLeftDistanceDuringReverseCm = -1.0f;
  resetAvoidanceConfirmCounters();
  frontObstacleLatched = true;
  setAvoidanceMode(AVOIDANCE_REVERSE, nowMs, "front obstacle on sensor 4");
}

void beginSideAvoidance(bool moveLeft, unsigned long nowMs, const String &reason) {
  avoidanceSidestepDurationMs = SIDE_SIDESTEP_DURATION_MS;
  resetAvoidanceConfirmCounters();
  setAvoidanceMode(moveLeft ? AVOIDANCE_SIDESTEP_LEFT : AVOIDANCE_SIDESTEP_RIGHT, nowMs, reason);
}

bool detectionSensorsReady(unsigned long nowMs) {
  return freshUltrasonicDistanceCm(RIGHT_SENSOR_INDEX, nowMs) >= 0.0f
    && freshUltrasonicDistanceCm(LEFT_SENSOR_INDEX, nowMs) >= 0.0f
    && freshUltrasonicDistanceCm(FRONT_SENSOR_INDEX, nowMs) >= 0.0f;
}

void updateAvoidanceState(unsigned long nowMs) {
  float rightDistance = freshUltrasonicDistanceCm(RIGHT_SENSOR_INDEX, nowMs);
  float leftDistance = freshUltrasonicDistanceCm(LEFT_SENSOR_INDEX, nowMs);
  float frontDistance = freshUltrasonicDistanceCm(FRONT_SENSOR_INDEX, nowMs);

  if (frontObstacleLatched) {
    if (frontDistance < 0.0f || frontDistance > OBSTACLE_CLEAR_CM) {
      frontObstacleLatched = false;
    }
  }

  switch (activeAvoidanceMode) {
    case AVOIDANCE_NONE:
      if (nowMs < AVOIDANCE_STARTUP_SETTLE_MS || !detectionSensorsReady(nowMs)) {
        resetAvoidanceConfirmCounters();
        return;
      }

      frontObstacleConfirmCount =
        (!frontObstacleLatched && frontDistance > 0.0f && frontDistance <= OBSTACLE_TRIGGER_CM)
          ? bumpConfirmCounter(frontObstacleConfirmCount)
          : 0;
      rightObstacleConfirmCount =
        (rightDistance > 0.0f && rightDistance <= OBSTACLE_TRIGGER_CM
          && (leftDistance < 0.0f || rightDistance <= leftDistance))
          ? bumpConfirmCounter(rightObstacleConfirmCount)
          : 0;
      leftObstacleConfirmCount =
        (leftDistance > 0.0f && leftDistance <= OBSTACLE_TRIGGER_CM
          && (rightDistance < 0.0f || leftDistance < rightDistance))
          ? bumpConfirmCounter(leftObstacleConfirmCount)
          : 0;

      if (frontObstacleConfirmCount >= AVOIDANCE_CONFIRMATION_COUNT) {
        beginFrontAvoidance(nowMs);
        return;
      }

      if (rightObstacleConfirmCount >= AVOIDANCE_CONFIRMATION_COUNT) {
        beginSideAvoidance(true, nowMs, "right obstacle on sensor 1");
        return;
      }

      if (leftObstacleConfirmCount >= AVOIDANCE_CONFIRMATION_COUNT) {
        beginSideAvoidance(false, nowMs, "left obstacle on sensor 3");
        return;
      }

      return;

    case AVOIDANCE_REVERSE:
      if (rightDistance > bestRightDistanceDuringReverseCm) {
        bestRightDistanceDuringReverseCm = rightDistance;
      }
      if (leftDistance > bestLeftDistanceDuringReverseCm) {
        bestLeftDistanceDuringReverseCm = leftDistance;
      }

      if ((nowMs - avoidanceModeStartedAtMs) >= FRONT_REVERSE_DURATION_MS) {
        bool moveRight = bestRightDistanceDuringReverseCm > bestLeftDistanceDuringReverseCm;
        if (bestRightDistanceDuringReverseCm < 0.0f && bestLeftDistanceDuringReverseCm < 0.0f) {
          moveRight = false;
        }
        avoidanceSidestepDurationMs = FRONT_SIDESTEP_DURATION_MS;
        setAvoidanceMode(
          moveRight ? AVOIDANCE_SIDESTEP_RIGHT : AVOIDANCE_SIDESTEP_LEFT,
          nowMs,
          moveRight ? "sensor 1 had more clearance during reverse" : "sensor 3 had more clearance during reverse"
        );
      }
      return;

    case AVOIDANCE_SIDESTEP_LEFT:
      if ((nowMs - avoidanceModeStartedAtMs) >= avoidanceSidestepDurationMs) {
        setAvoidanceMode(AVOIDANCE_COOLDOWN, nowMs, "left sidestep complete");
      }
      return;

    case AVOIDANCE_SIDESTEP_RIGHT:
      if ((nowMs - avoidanceModeStartedAtMs) >= avoidanceSidestepDurationMs) {
        setAvoidanceMode(AVOIDANCE_COOLDOWN, nowMs, "right sidestep complete");
      }
      return;

    case AVOIDANCE_COOLDOWN:
      if ((nowMs - avoidanceModeStartedAtMs) >= AVOIDANCE_COOLDOWN_MS) {
        activeAvoidanceMode = AVOIDANCE_NONE;
        resetAvoidanceConfirmCounters();
      }
      return;
  }
}

void effectiveMotionTargets(float &vx, float &vy, float &wz, unsigned long nowMs) {
  vx = vx_cmd;
  vy = vy_cmd;
  wz = wz_cmd;

  updateAvoidanceState(nowMs);

  switch (activeAvoidanceMode) {
    case AVOIDANCE_REVERSE:
      vx = AVOIDANCE_REVERSE_SPEED;
      vy = 0.0f;
      wz = 0.0f;
      break;
    case AVOIDANCE_SIDESTEP_LEFT:
      vx = 0.0f;
      vy = -AVOIDANCE_SIDESTEP_SPEED;
      wz = 0.0f;
      break;
    case AVOIDANCE_SIDESTEP_RIGHT:
      vx = 0.0f;
      vy = AVOIDANCE_SIDESTEP_SPEED;
      wz = 0.0f;
      break;
    case AVOIDANCE_COOLDOWN:
    case AVOIDANCE_NONE:
    default:
      break;
  }
}

void updateUltrasonicSensors(unsigned long nowMs) {
  if ((nowMs - lastUltrasonicPollAtMs) < ULTRASONIC_POLL_INTERVAL_MS) {
    return;
  }

  lastUltrasonicPollAtMs = nowMs;

  UltrasonicPins sensor = ultrasonicSensors[nextUltrasonicSensorIndex];
  float candidate = readSensorDistanceCm(sensor);
  ultrasonicDistances[nextUltrasonicSensorIndex] = candidate;
  ultrasonicSampleAtMs[nextUltrasonicSensorIndex] = nowMs;
  nextUltrasonicSensorIndex = (nextUltrasonicSensorIndex + 1) % ULTRASONIC_SENSOR_COUNT;

  recomputeNearestObstacle(nowMs);
}

void sendUltrasonicTelemetry() {
  piSerial.print("ULTRASONIC ");
  piSerial.println(nearestObstacleCm, 2);
}

void processIncomingCommandLine(String &buffer, char incoming, bool sendAckToPiLink) {
  if (incoming == '\n' || incoming == '\r') {
    if (buffer.length() == 0) {
      return;
    }

    float vx = 0.0f;
    float vy = 0.0f;
    float wz = 0.0f;
    bool rcOverride = webControlActive();
    if (parseMotionCommand(buffer, vx, vy, wz)) {
      if (!rcOverride) {
        vx_cmd = vx;
        vy_cmd = vy;
        wz_cmd = wz;
        lastCommandMs = millis();
        activeCommandSource = SOURCE_PI_SERIAL;
      }
      if (sendAckToPiLink) {
        piLinkPrintln(rcOverride ? "OK MOVE OVERRIDDEN_BY_WEB" : "OK MOVE");
      } else {
        Serial.println(rcOverride ? "OK MOVE OVERRIDDEN_BY_WEB" : "OK MOVE");
      }
    } else {
      CaneCommand command = parseCommand(buffer);
      if (!rcOverride) {
        commandToTargets(command, vx_cmd, vy_cmd, wz_cmd);
        lastCommandMs = millis();
        activeCommandSource = SOURCE_PI_SERIAL;
      }
      if (sendAckToPiLink) {
        piLinkPrint("OK ");
        piLinkPrintln(rcOverride ? String(commandName(command)) + " OVERRIDDEN_BY_WEB" : commandName(command));
      } else {
        Serial.print("OK ");
        Serial.println(rcOverride ? String(commandName(command)) + " OVERRIDDEN_BY_WEB" : commandName(command));
      }
    }
    buffer = "";
    return;
  }

  buffer += incoming;
}

void handleSerialInput() {
  while (piSerial.available() > 0) {
    char incoming = piSerial.read();
    processIncomingCommandLine(serialLine, incoming, true);
  }
}

void handleUsbSerialInput() {
  while (Serial.available() > 0) {
    char incoming = (char)Serial.read();
    processIncomingCommandLine(usbSerialLine, incoming, false);
  }
}

void handleRoot() {
  server.send_P(200, "text/html", INDEX_HTML);
}

void handleUpdatePage() {
  server.send_P(200, "text/html", UPDATE_HTML);
}

void handleCmd() {
  if (server.hasArg("vx")) vx_cmd = clampf(server.arg("vx").toFloat(), -1.0f, 1.0f);
  if (server.hasArg("vy")) vy_cmd = clampf(server.arg("vy").toFloat(), -1.0f, 1.0f);
  if (server.hasArg("wz")) wz_cmd = clampf(server.arg("wz").toFloat(), -1.0f, 1.0f);

  vx_cmd = applyDeadzone(vx_cmd, DEADZONE);
  vy_cmd = applyDeadzone(vy_cmd, DEADZONE);
  wz_cmd = applyDeadzone(wz_cmd, DEADZONE);
  lastCommandMs = millis();
  lastWebCommandMs = lastCommandMs;
  activeCommandSource = SOURCE_WEB;

  server.send(200, "text/plain", "OK");
}

void handleStop() {
  stopTargets();
  lastCommandMs = millis();
  lastWebCommandMs = lastCommandMs;
  activeCommandSource = SOURCE_WEB;
  server.send(200, "text/plain", "STOPPED");
}

void handleUpdateUpload() {
  HTTPUpload &upload = server.upload();

  if (upload.status == UPLOAD_FILE_START) {
    debugLog(String("OTA upload start: ") + upload.filename);
    stopTargets();
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
      Update.printError(Serial);
    }
    return;
  }

  if (upload.status == UPLOAD_FILE_WRITE) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
      Update.printError(Serial);
    }
    return;
  }

  if (upload.status == UPLOAD_FILE_END) {
    if (Update.end(true)) {
      debugLog(String("OTA upload complete: ") + upload.totalSize + " bytes");
    } else {
      Update.printError(Serial);
    }
    return;
  }

  if (upload.status == UPLOAD_FILE_ABORTED) {
    Update.end();
    debugLog("OTA upload aborted");
  }
}

void handleUpdateResult() {
  bool success = !Update.hasError();
  server.send(
    success ? 200 : 500,
    "text/plain",
    success ? "Update successful. Rebooting..." : "Update failed."
  );

  if (success) {
    delay(300);
    ESP.restart();
  }
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
  server.on("/stop", HTTP_GET, handleStop);
  server.on("/update", HTTP_GET, handleUpdatePage);
  server.on("/update", HTTP_POST, handleUpdateResult, handleUpdateUpload);
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
    pinMode(sensor.echo, INPUT_PULLDOWN);
    digitalWrite(sensor.trigger, LOW);
  }
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
  motorOff(m1);
  motorOff(m2);
  motorOff(m3);
  setupMotorUnitImu();

  startWiFiAP();
  setupWeb();

  lastLoopUs = micros();
  lastCommandMs = millis();
  debugLog("ESP32-S3 omni raw commutation ready");
}

void loop() {
  server.handleClient();
  handleSerialInput();
  handleUsbSerialInput();
  bool rcOverride = webControlActive();

  unsigned long nowMs = millis();

  if (!rcOverride) {
    updateMotorUnitImu();
    updateUltrasonicSensors(nowMs);
  } else {
    activeAvoidanceMode = AVOIDANCE_NONE;
  }

  if (!rcOverride && nowMs - lastMotorImuTelemetryAtMs >= 200) {
    lastMotorImuTelemetryAtMs = nowMs;
    sendMotorImuTelemetry();
  }
  if (!rcOverride && nowMs - lastUltrasonicTelemetryAtMs >= 120) {
    lastUltrasonicTelemetryAtMs = nowMs;
    sendUltrasonicTelemetry();
  }

  unsigned long nowUs = micros();
  float dt = (nowUs - lastLoopUs) * 1e-6f;
  lastLoopUs = nowUs;
  dt = clampf(dt, 0.0005f, 0.05f);

  if (activeCommandSource == SOURCE_WEB && millis() - lastCommandMs > COMMAND_TIMEOUT_MS) {
    stopTargets();
  }

  float effectiveVx = 0.0f;
  float effectiveVy = 0.0f;
  float effectiveWz = 0.0f;
  effectiveMotionTargets(effectiveVx, effectiveVy, effectiveWz, nowMs);

  float w1, w2, w3;
  omniMix(effectiveVx, effectiveVy, effectiveWz, w1, w2, w3);

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

  printStatus();
}
