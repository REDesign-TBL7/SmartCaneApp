#include <Arduino.h>

// ESP32 motor controller for the smart cane.
//
// The Raspberry Pi sends one command per line over serial:
// LEFT, RIGHT, FORWARD, or STOP.
//
// This sketch is based on the original test_1.ino startup test. It keeps the
// same ESP32-S3 pin map and 6-step DRV8313 commutation pattern, but adds a
// serial command loop so the Pi can control the motors during app navigation.
//
// The motor-unit IMU also belongs on this ESP32. The sketch exposes a telemetry
// line for it now; wire the real IMU driver into updateMotorUnitImu() when the
// exact sensor/library is finalized.

// =========================
// PIN MAP
// =========================
// Motor 1
#define M1_IN1 4
#define M1_IN2 5
#define M1_IN3 6
#define M1_EN  7

// Motor 2
#define M2_IN1 8
#define M2_IN2 9
#define M2_IN3 10
#define M2_EN  11

// Motor 3
#define M3_IN1 12
#define M3_IN2 13
#define M3_IN3 14
#define M3_EN  15

// =========================
// TUNING
// =========================
int alignTimeMs = 500;
int startupDelayMs = 30;
int finalRunDelayMs = 6;
int rampRepeats = 2;
bool runBootSelfTest = false;  // Keep false for normal cane use; avoids motion on power-up.

enum CaneCommand {
  CMD_STOP,
  CMD_FORWARD,
  CMD_LEFT,
  CMD_RIGHT
};

struct MotorPins {
  int in1;
  int in2;
  int in3;
  int en;
};

struct MotorDirections {
  int m1;
  int m2;
  int m3;
};

MotorPins motor1 = { M1_IN1, M1_IN2, M1_IN3, M1_EN };
MotorPins motor2 = { M2_IN1, M2_IN2, M2_IN3, M2_EN };
MotorPins motor3 = { M3_IN1, M3_IN2, M3_IN3, M3_EN };

CaneCommand activeCommand = CMD_STOP;
String serialLine = "";
int currentStep = 0;
unsigned long lastStepAtMs = 0;
unsigned long lastMotorImuTelemetryAtMs = 0;

bool motorImuAvailable = false;  // TODO: Set true after wiring the real motor-unit IMU.
float motorImuHeadingDegrees = 0.0;
float motorImuPitchDegrees = 0.0;
float motorImuRollDegrees = 0.0;

// These directions mirror the old Pi inverse-kinematics signs:
// FORWARD: motor 1 forward, motors 2 and 3 reverse
// LEFT: all motors forward
// RIGHT: all motors reverse
//
// TODO: Calibrate these signs on the physical cane and adjust if the haptic
// tug direction is inverted.
MotorDirections directionsForCommand(CaneCommand command) {
  switch (command) {
    case CMD_FORWARD:
      return { 1, -1, -1 };
    case CMD_LEFT:
      return { 1, 1, 1 };
    case CMD_RIGHT:
      return { -1, -1, -1 };
    case CMD_STOP:
    default:
      return { 0, 0, 0 };
  }
}

void setStep(int in1, int in2, int in3, int step) {
  switch (step) {
    case 0:
      digitalWrite(in1, HIGH);
      digitalWrite(in2, LOW);
      digitalWrite(in3, LOW);
      break;
    case 1:
      digitalWrite(in1, HIGH);
      digitalWrite(in2, HIGH);
      digitalWrite(in3, LOW);
      break;
    case 2:
      digitalWrite(in1, LOW);
      digitalWrite(in2, HIGH);
      digitalWrite(in3, LOW);
      break;
    case 3:
      digitalWrite(in1, LOW);
      digitalWrite(in2, HIGH);
      digitalWrite(in3, HIGH);
      break;
    case 4:
      digitalWrite(in1, LOW);
      digitalWrite(in2, LOW);
      digitalWrite(in3, HIGH);
      break;
    case 5:
      digitalWrite(in1, HIGH);
      digitalWrite(in2, LOW);
      digitalWrite(in3, HIGH);
      break;
  }
}

void setMotorOff(MotorPins motor) {
  digitalWrite(motor.in1, LOW);
  digitalWrite(motor.in2, LOW);
  digitalWrite(motor.in3, LOW);
}

void allOff() {
  setMotorOff(motor1);
  setMotorOff(motor2);
  setMotorOff(motor3);
}

int wrappedStep(int step) {
  while (step < 0) {
    step += 6;
  }
  while (step > 5) {
    step -= 6;
  }
  return step;
}

void applyMotorDirection(MotorPins motor, int baseStep, int direction) {
  if (direction == 0) {
    setMotorOff(motor);
    return;
  }

  int motorStep = direction > 0 ? baseStep : 5 - baseStep;
  setStep(motor.in1, motor.in2, motor.in3, wrappedStep(motorStep));
}

void applyDirections(MotorDirections directions, int step) {
  applyMotorDirection(motor1, step, directions.m1);
  applyMotorDirection(motor2, step, directions.m2);
  applyMotorDirection(motor3, step, directions.m3);
}

void startupRamp() {
  MotorDirections forwardDirections = directionsForCommand(CMD_FORWARD);

  applyDirections(forwardDirections, 0);
  delay(alignTimeMs);

  for (int d = startupDelayMs; d >= finalRunDelayMs; d--) {
    for (int r = 0; r < rampRepeats; r++) {
      for (int s = 0; s < 6; s++) {
        applyDirections(forwardDirections, s);
        delay(d);
      }
    }
  }

  allOff();
}

CaneCommand parseCommand(String line) {
  line.trim();
  line.toUpperCase();

  if (line.startsWith("CMD ")) {
    line = line.substring(4);
    line.trim();
  }

  if (line == "FORWARD") {
    return CMD_FORWARD;
  }
  if (line == "LEFT") {
    return CMD_LEFT;
  }
  if (line == "RIGHT") {
    return CMD_RIGHT;
  }
  return CMD_STOP;
}

const char* commandName(CaneCommand command) {
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

void handleSerialInput() {
  while (Serial.available() > 0) {
    char incoming = Serial.read();
    if (incoming == '\n' || incoming == '\r') {
      if (serialLine.length() == 0) {
        continue;
      }

      activeCommand = parseCommand(serialLine);
      Serial.print("OK ");
      Serial.println(commandName(activeCommand));

      if (activeCommand == CMD_STOP) {
        allOff();
      }

      serialLine = "";
    } else {
      serialLine += incoming;
    }
  }
}

void updateMotorUnitImu() {
  // TODO: Read the ESP32-side motor-unit IMU here.
  //
  // This IMU should describe the motor/tip unit orientation used for haptic
  // motor control. Do not use the Pi handle IMU here; that one is reserved for
  // camera deblur/stabilization.
  //
  // Example final behavior:
  // motorImuAvailable = true;
  // motorImuHeadingDegrees = fused yaw heading from the ESP32 IMU;
  // motorImuPitchDegrees = fused pitch;
  // motorImuRollDegrees = fused roll;
}

void sendMotorImuTelemetry() {
  Serial.print("MOTOR_IMU ");
  Serial.print(motorImuAvailable ? 1 : 0);
  Serial.print(" ");
  Serial.print(motorImuHeadingDegrees, 2);
  Serial.print(" ");
  Serial.print(motorImuPitchDegrees, 2);
  Serial.print(" ");
  Serial.println(motorImuRollDegrees, 2);
}

void setupMotorPins(MotorPins motor) {
  pinMode(motor.in1, OUTPUT);
  pinMode(motor.in2, OUTPUT);
  pinMode(motor.in3, OUTPUT);
  pinMode(motor.en, OUTPUT);
  digitalWrite(motor.en, HIGH);
}

void setup() {
  Serial.begin(115200);
  Serial.println("ESP32-S3 smart cane motor controller ready");

  setupMotorPins(motor1);
  setupMotorPins(motor2);
  setupMotorPins(motor3);

  allOff();
  delay(300);

  if (runBootSelfTest) {
    // Optional: keeps the original test_1.ino startup behavior for bench testing.
    startupRamp();
  }
}

void loop() {
  handleSerialInput();
  updateMotorUnitImu();

  unsigned long nowMs = millis();
  if (nowMs - lastMotorImuTelemetryAtMs >= 200) {
    lastMotorImuTelemetryAtMs = nowMs;
    sendMotorImuTelemetry();
  }

  if (activeCommand == CMD_STOP) {
    delay(5);
    return;
  }

  if (nowMs - lastStepAtMs < (unsigned long)finalRunDelayMs) {
    return;
  }

  lastStepAtMs = nowMs;
  currentStep = wrappedStep(currentStep + 1);
  applyDirections(directionsForCommand(activeCommand), currentStep);
}
