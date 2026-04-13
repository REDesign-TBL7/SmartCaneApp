"""
Pi-to-ESP32 motor bridge.

The Raspberry Pi no longer drives the motor GPIO pins directly. The Pi receives
commands from the iPhone app over WebSocket, applies safety logic, then forwards
LEFT / RIGHT / FORWARD / STOP to the ESP32 over serial.
"""

import os
import logging
from dataclasses import dataclass

try:
    import serial
except ImportError:  # pragma: no cover - lets local dev run without pyserial
    serial = None


VALID_COMMANDS = {"LEFT", "RIGHT", "FORWARD", "STOP"}
DEFAULT_BAUD_RATE = 115200
DEFAULT_SERIAL_PORTS = (
    "/dev/serial0",
    "/dev/ttyUSB0",
    "/dev/ttyACM0",
)

logger = logging.getLogger(__name__)


@dataclass
class MotorCommand:
    command: str
    sent_to_esp32: bool


@dataclass
class MotorIMUTelemetry:
    """Latest IMU sample from the ESP32 motor unit."""

    available: bool = False
    heading_degrees: float | None = None
    pitch_degrees: float | None = None
    roll_degrees: float | None = None


@dataclass
class UltrasonicTelemetry:
    nearest_obstacle_cm: float = -1.0


class MotorController:
    def __init__(self) -> None:
        self.serial_port_path = os.getenv("SMARTCANE_ESP32_PORT")
        self.baud_rate = int(os.getenv("SMARTCANE_ESP32_BAUD", DEFAULT_BAUD_RATE))
        self.serial_connection = None
        self.last_command = MotorCommand(command="STOP", sent_to_esp32=False)
        self.last_serial_line = "STOP"
        self.latest_motor_imu = MotorIMUTelemetry()
        self.latest_ultrasonic = UltrasonicTelemetry()
        self.status_message = "ESP32 motor serial link not connected"

        self._connect_serial()
        logger.info("Motor controller initialized: %s", self.status_message)

    def stop(self) -> None:
        self.apply_discrete_command("STOP")

    def apply_discrete_command(self, cmd: str) -> MotorCommand:
        self.poll_motor_imu()
        command = self._normalize_command(cmd)

        # Avoid spamming the ESP32 every 0.2 seconds while the same command is active.
        if command == self.last_command.command and self.last_command.sent_to_esp32 and self.last_serial_line == command:
            logger.debug("Skipping duplicate motor command %s", command)
            return self.last_command

        was_sent = self._send_line_to_esp32(command, f"Sent motor command to ESP32: {command}")
        self.last_command = MotorCommand(command=command, sent_to_esp32=was_sent)
        logger.debug("Motor command result command=%s sent=%s", command, was_sent)
        return self.last_command

    def poll_motor_imu(self) -> MotorIMUTelemetry:
        """Read ESP32 motor-unit IMU lines without blocking.

        Expected line format from ESP32:
        MOTOR_IMU <available> <headingDegrees> <pitchDegrees> <rollDegrees>
        """
        if self.serial_connection is None:
            self.latest_motor_imu = MotorIMUTelemetry()
            self.latest_ultrasonic = UltrasonicTelemetry()
            return self.latest_motor_imu

        try:
            while self.serial_connection.in_waiting:
                line = self.serial_connection.readline().decode("utf-8", errors="ignore").strip()
                self._handle_esp32_line(line)
        except serial.SerialException as error:
            self.status_message = f"ESP32 serial read failed: {error}"
            self.serial_connection = None
            self.latest_motor_imu = MotorIMUTelemetry()
            self.latest_ultrasonic = UltrasonicTelemetry()
            logger.exception("ESP32 serial read failed")

        return self.latest_motor_imu

    def close(self) -> None:
        self.stop()

        if self.serial_connection is not None:
            self.serial_connection.close()
            self.serial_connection = None

    def _connect_serial(self) -> None:
        if serial is None:
            self.status_message = "pyserial is not installed; cannot connect to ESP32"
            return

        port = self.serial_port_path or self._first_existing_port()
        if port is None:
            self.status_message = "No ESP32 serial port found"
            return

        try:
            self.serial_connection = serial.Serial(
                port=port,
                baudrate=self.baud_rate,
                timeout=0.1,
                write_timeout=0.1,
            )
            self.status_message = f"ESP32 motor link active on {port}"
            logger.info("ESP32 serial connected on %s at %s baud", port, self.baud_rate)
        except serial.SerialException as error:
            self.serial_connection = None
            self.status_message = f"ESP32 serial connection failed: {error}"
            logger.exception("ESP32 serial connection failed")

    def _send_line_to_esp32(self, line: str, status_message: str) -> bool:
        if self.serial_connection is None:
            self.status_message = "ESP32 motor command dropped; serial link unavailable"
            return False

        try:
            self.serial_connection.write(f"{line}\n".encode("utf-8"))
            self.serial_connection.flush()
            self.status_message = status_message
            self.last_serial_line = line
            logger.info("%s", status_message)
            return True
        except serial.SerialException as error:
            self.status_message = f"ESP32 serial write failed: {error}"
            self.serial_connection = None
            logger.exception("ESP32 serial write failed")
            return False

    def _first_existing_port(self) -> str | None:
        for port in DEFAULT_SERIAL_PORTS:
            if os.path.exists(port):
                return port
        return None

    @staticmethod
    def _normalize_command(cmd: str) -> str:
        command = (cmd or "STOP").strip().upper()
        return command if command in VALID_COMMANDS else "STOP"

    def _handle_esp32_line(self, line: str) -> None:
        if not line:
            return

        if line.startswith("OK "):
            logger.debug("ESP32 ack: %s", line)
            return

        if line.startswith("MOTOR_IMU "):
            self._parse_motor_imu_line(line)
            return

        if line.startswith("ULTRASONIC "):
            self._parse_ultrasonic_line(line)
            return

    def _parse_motor_imu_line(self, line: str) -> None:
        parts = line.split()
        if len(parts) != 5:
            return

        available = parts[1] == "1"
        if not available:
            self.latest_motor_imu = MotorIMUTelemetry(available=False)
            logger.debug("ESP32 motor IMU unavailable")
            return

        try:
            self.latest_motor_imu = MotorIMUTelemetry(
                available=True,
                heading_degrees=float(parts[2]),
                pitch_degrees=float(parts[3]),
                roll_degrees=float(parts[4]),
            )
            logger.debug(
                "ESP32 motor IMU heading=%s pitch=%s roll=%s",
                self.latest_motor_imu.heading_degrees,
                self.latest_motor_imu.pitch_degrees,
                self.latest_motor_imu.roll_degrees,
            )
        except ValueError:
            self.latest_motor_imu = MotorIMUTelemetry(available=False)
            logger.warning("Failed to parse ESP32 motor IMU line: %s", line)

    def _parse_ultrasonic_line(self, line: str) -> None:
        parts = line.split()
        if len(parts) != 2:
            logger.warning("Failed to parse ESP32 ultrasonic line: %s", line)
            return

        try:
            self.latest_ultrasonic = UltrasonicTelemetry(nearest_obstacle_cm=float(parts[1]))
            logger.debug("ESP32 ultrasonic nearest obstacle=%s", self.latest_ultrasonic.nearest_obstacle_cm)
        except ValueError:
            self.latest_ultrasonic = UltrasonicTelemetry()
            logger.warning("Failed to parse ESP32 ultrasonic distance: %s", line)
