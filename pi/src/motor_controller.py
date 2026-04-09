"""
Pi-to-ESP32 motor bridge.

The Raspberry Pi no longer drives the motor GPIO pins directly. The Pi receives
commands from the iPhone app over WebSocket, applies safety logic, then forwards
the final LEFT / RIGHT / FORWARD / STOP command to the ESP32 over serial.
"""

import os
from dataclasses import dataclass

try:
    import serial
except ImportError:  # pragma: no cover - lets local dev run without pyserial
    serial = None


VALID_COMMANDS = {"LEFT", "RIGHT", "FORWARD", "STOP"}
DEFAULT_BAUD_RATE = 115200
DEFAULT_SERIAL_PORTS = (
    "/dev/ttyUSB0",
    "/dev/ttyACM0",
    "/dev/serial0",
)


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


class MotorController:
    def __init__(self) -> None:
        self.serial_port_path = os.getenv("SMARTCANE_ESP32_PORT")
        self.baud_rate = int(os.getenv("SMARTCANE_ESP32_BAUD", DEFAULT_BAUD_RATE))
        self.serial_connection = None
        self.last_command = MotorCommand(command="STOP", sent_to_esp32=False)
        self.latest_motor_imu = MotorIMUTelemetry()
        self.status_message = "ESP32 motor serial link not connected"

        self._connect_serial()

    def stop(self) -> None:
        self.apply_discrete_command("STOP")

    def apply_discrete_command(self, cmd: str) -> MotorCommand:
        self.poll_motor_imu()
        command = self._normalize_command(cmd)

        # Avoid spamming the ESP32 every 0.2 seconds while the same command is active.
        if command == self.last_command.command and self.last_command.sent_to_esp32:
            return self.last_command

        was_sent = self._send_command_to_esp32(command)
        self.last_command = MotorCommand(command=command, sent_to_esp32=was_sent)
        return self.last_command

    def poll_motor_imu(self) -> MotorIMUTelemetry:
        """Read ESP32 motor-unit IMU lines without blocking.

        Expected line format from ESP32:
        MOTOR_IMU <available> <headingDegrees> <pitchDegrees> <rollDegrees>
        """
        if self.serial_connection is None:
            self.latest_motor_imu = MotorIMUTelemetry()
            return self.latest_motor_imu

        try:
            while self.serial_connection.in_waiting:
                line = self.serial_connection.readline().decode("utf-8", errors="ignore").strip()
                self._handle_esp32_line(line)
        except serial.SerialException as error:
            self.status_message = f"ESP32 serial read failed: {error}"
            self.serial_connection = None
            self.latest_motor_imu = MotorIMUTelemetry()

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
        except serial.SerialException as error:
            self.serial_connection = None
            self.status_message = f"ESP32 serial connection failed: {error}"

    def _send_command_to_esp32(self, command: str) -> bool:
        if self.serial_connection is None:
            self.status_message = "ESP32 motor command dropped; serial link unavailable"
            return False

        try:
            self.serial_connection.write(f"{command}\n".encode("utf-8"))
            self.serial_connection.flush()
            self.status_message = f"Sent motor command to ESP32: {command}"
            return True
        except serial.SerialException as error:
            self.status_message = f"ESP32 serial write failed: {error}"
            self.serial_connection = None
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
            return

        if line.startswith("MOTOR_IMU "):
            self._parse_motor_imu_line(line)

    def _parse_motor_imu_line(self, line: str) -> None:
        parts = line.split()
        if len(parts) != 5:
            return

        available = parts[1] == "1"
        if not available:
            self.latest_motor_imu = MotorIMUTelemetry(available=False)
            return

        try:
            self.latest_motor_imu = MotorIMUTelemetry(
                available=True,
                heading_degrees=float(parts[2]),
                pitch_degrees=float(parts[3]),
                roll_degrees=float(parts[4]),
            )
        except ValueError:
            self.latest_motor_imu = MotorIMUTelemetry(available=False)
