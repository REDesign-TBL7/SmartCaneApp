# Calibration

## IMUs

- Motor-unit IMU: mounted on ESP32 motor unit, used for motor/tip heading and motor guidance.
- Handle IMU: mounted on Pi/handle side, used for camera deblur/stabilization.
- Calibrate both gyro biases at startup while cane is stationary.
- Re-check motor-unit heading drift before each test session.
- Re-check handle IMU stability before camera/VLM deblur testing.

## Ultrasonic

- Measure known distances and tune conversion/filters.
- Validate emergency threshold in controlled indoor setup.

## Motors

- Verify wheel direction mapping.
- Tune per-wheel gain to track straight movement.
