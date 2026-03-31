from dataclasses import dataclass

try:
    import RPi.GPIO as GPIO
except ImportError:  # pragma: no cover - for local dev
    GPIO = None


@dataclass
class MotorCommand:
    wheel_a: float
    wheel_b: float
    wheel_c: float


class _MotorChannel:
    def __init__(
        self, in1: int, in2: int, in3: int, en_pin: int, pwm_hz: int = 16000
    ) -> None:
        self.in1 = in1
        self.in2 = in2
        self.in3 = in3
        self.en_pin = en_pin
        self.pwm_hz = pwm_hz
        self.pwm = None

    def setup(self) -> None:
        if GPIO is None:
            return
        GPIO.setup(self.in1, GPIO.OUT)
        GPIO.setup(self.in2, GPIO.OUT)
        GPIO.setup(self.in3, GPIO.OUT)
        GPIO.setup(self.en_pin, GPIO.OUT)
        self.pwm = GPIO.PWM(self.en_pin, self.pwm_hz)
        self.pwm.start(0)

    def _set_phase(self, a: int, b: int, c: int) -> None:
        if GPIO is None:
            return
        GPIO.output(self.in1, GPIO.HIGH if a else GPIO.LOW)
        GPIO.output(self.in2, GPIO.HIGH if b else GPIO.LOW)
        GPIO.output(self.in3, GPIO.HIGH if c else GPIO.LOW)

    def drive(self, value: float) -> None:
        duty = max(0.0, min(100.0, abs(value) * 100.0))
        if GPIO is None:
            return

        if value > 0.02:
            self._set_phase(1, 0, 1)
        elif value < -0.02:
            self._set_phase(0, 1, 1)
        else:
            self._set_phase(0, 0, 0)
        self.pwm.ChangeDutyCycle(duty)

    def stop(self) -> None:
        if GPIO is None:
            return
        self._set_phase(0, 0, 0)
        if self.pwm is not None:
            self.pwm.ChangeDutyCycle(0)


class MotorController:
    def __init__(self, max_speed: float = 0.6) -> None:
        self.max_speed = max_speed
        self.last_command = MotorCommand(0.0, 0.0, 0.0)

        self.motor_a = _MotorChannel(in1=25, in2=26, in3=27, en_pin=14)
        self.motor_b = _MotorChannel(in1=32, in2=33, in3=13, en_pin=12)
        self.motor_c = _MotorChannel(in1=18, in2=19, in3=21, en_pin=5)

        if GPIO is not None:
            GPIO.setmode(GPIO.BOARD)
            self.motor_a.setup()
            self.motor_b.setup()
            self.motor_c.setup()

    def stop(self) -> None:
        self.last_command = MotorCommand(0.0, 0.0, 0.0)
        self.motor_a.stop()
        self.motor_b.stop()
        self.motor_c.stop()

    def inverse_kinematics(self, vx: float, vy: float, omega: float) -> MotorCommand:
        wheel_a = vx - omega
        wheel_b = (-0.5 * vx + 0.866 * vy) - omega
        wheel_c = (-0.5 * vx - 0.866 * vy) - omega

        return MotorCommand(
            wheel_a=max(-self.max_speed, min(self.max_speed, wheel_a)),
            wheel_b=max(-self.max_speed, min(self.max_speed, wheel_b)),
            wheel_c=max(-self.max_speed, min(self.max_speed, wheel_c)),
        )

    def apply_discrete_command(self, cmd: str) -> MotorCommand:
        if cmd == "FORWARD":
            self.last_command = self.inverse_kinematics(vx=0.35, vy=0.0, omega=0.0)
        elif cmd == "LEFT":
            self.last_command = self.inverse_kinematics(vx=0.0, vy=0.0, omega=-0.3)
        elif cmd == "RIGHT":
            self.last_command = self.inverse_kinematics(vx=0.0, vy=0.0, omega=0.3)
        else:
            self.stop()
            return self.last_command

        self.motor_a.drive(self.last_command.wheel_a)
        self.motor_b.drive(self.last_command.wheel_b)
        self.motor_c.drive(self.last_command.wheel_c)
        return self.last_command

    def close(self) -> None:
        self.stop()
        if GPIO is not None:
            GPIO.cleanup()
