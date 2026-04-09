import time

try:
    import RPi.GPIO as GPIO
except ImportError:  # pragma: no cover - for local dev
    GPIO = None


class HCSR04Sensor:
    def __init__(
        self, trigger_pin: int, echo_pin: int, timeout_sec: float = 0.03
    ) -> None:
        self.trigger_pin = trigger_pin
        self.echo_pin = echo_pin
        self.timeout_sec = timeout_sec

    def setup(self) -> None:
        if GPIO is None:
            return
        GPIO.setup(self.trigger_pin, GPIO.OUT)
        GPIO.setup(self.echo_pin, GPIO.IN)
        GPIO.output(self.trigger_pin, False)

    def distance_cm(self) -> float:
        if GPIO is None:
            return -1.0

        GPIO.output(self.trigger_pin, True)
        time.sleep(0.00001)
        GPIO.output(self.trigger_pin, False)

        pulse_start = time.monotonic()
        timeout = pulse_start + self.timeout_sec

        while GPIO.input(self.echo_pin) == 0:
            pulse_start = time.monotonic()
            if pulse_start > timeout:
                return -1.0

        pulse_end = time.monotonic()
        timeout = pulse_end + self.timeout_sec
        while GPIO.input(self.echo_pin) == 1:
            pulse_end = time.monotonic()
            if pulse_end > timeout:
                return -1.0

        duration = pulse_end - pulse_start
        return (duration * 34300) / 2


class UltrasonicManager:
    def __init__(self, emergency_stop_cm: float = 45.0) -> None:
        self.emergency_stop_cm = emergency_stop_cm
        self.sensors = [
            HCSR04Sensor(trigger_pin=7, echo_pin=11),
            HCSR04Sensor(trigger_pin=15, echo_pin=16),
            HCSR04Sensor(trigger_pin=22, echo_pin=23),
        ]

        if GPIO is not None:
            GPIO.setmode(GPIO.BOARD)
            for sensor in self.sensors:
                sensor.setup()

    def read_nearest_obstacle_cm(self) -> float:
        readings = [sensor.distance_cm() for sensor in self.sensors]
        valid = [cm for cm in readings if cm > 0]
        if not valid:
            return -1.0
        return min(valid)

    def is_emergency(self, obstacle_cm: float) -> bool:
        return obstacle_cm >= 0 and obstacle_cm < self.emergency_stop_cm

    def close(self) -> None:
        if GPIO is not None:
            GPIO.cleanup()
