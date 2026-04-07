#include <Arduino.h>

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
int alignTimeMs      = 500;   // hold one step so rotor aligns
int startupDelayMs   = 30;    // slow start
int finalRunDelayMs  = 6;     // faster running speed
int rampRepeats      = 2;     // how many times to repeat each delay value

// =========================
// HELPERS
// =========================
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

void allOff() {
  digitalWrite(M1_IN1, LOW);
  digitalWrite(M1_IN2, LOW);
  digitalWrite(M1_IN3, LOW);

  digitalWrite(M2_IN1, LOW);
  digitalWrite(M2_IN2, LOW);
  digitalWrite(M2_IN3, LOW);

  digitalWrite(M3_IN1, LOW);
  digitalWrite(M3_IN2, LOW);
  digitalWrite(M3_IN3, LOW);
}

void applyStepAll(int step) {
  setStep(M1_IN1, M1_IN2, M1_IN3, step);
  setStep(M2_IN1, M2_IN2, M2_IN3, step);
  setStep(M3_IN1, M3_IN2, M3_IN3, step);
}

void startupRamp() {
  // Align rotor
  applyStepAll(0);
  delay(alignTimeMs);

  // Ramp from slow to fast
  for (int d = startupDelayMs; d >= finalRunDelayMs; d--) {
    for (int r = 0; r < rampRepeats; r++) {
      for (int s = 0; s < 6; s++) {
        applyStepAll(s);
        delay(d);
      }
    }
  }
}

// =========================
// SETUP
// =========================
void setup() {
  Serial.begin(115200);
  Serial.println("ESP32-S3 3x DRV8313 startup test");

  pinMode(M1_IN1, OUTPUT);
  pinMode(M1_IN2, OUTPUT);
  pinMode(M1_IN3, OUTPUT);
  pinMode(M1_EN, OUTPUT);

  pinMode(M2_IN1, OUTPUT);
  pinMode(M2_IN2, OUTPUT);
  pinMode(M2_IN3, OUTPUT);
  pinMode(M2_EN, OUTPUT);

  pinMode(M3_IN1, OUTPUT);
  pinMode(M3_IN2, OUTPUT);
  pinMode(M3_IN3, OUTPUT);
  pinMode(M3_EN, OUTPUT);

  digitalWrite(M1_EN, HIGH);
  digitalWrite(M2_EN, HIGH);
  digitalWrite(M3_EN, HIGH);

  allOff();
  delay(300);

  startupRamp();
}

// =========================
// LOOP
// =========================
void loop() {
  for (int s = 0; s < 6; s++) {
    applyStepAll(s);
    delay(finalRunDelayMs);
  }
}
