import asyncio
import json
import logging
import os
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

from diagnostics_state import diagnostics_state
from websockets.server import WebSocketServerProtocol

logger = logging.getLogger(__name__)
DEVICE_NAME_PATH = Path("/etc/smartcane/device_name")
NETWORK_SCRIPT = Path(__file__).resolve().parents[2] / "infra" / "pi-network" / "smartcane_network.sh"


class CommServer:
    def __init__(self) -> None:
        self.clients: set[WebSocketServerProtocol] = set()
        self.latest_discrete_command = "STOP"
        self.latest_instruction_text = "No instruction"
        self.heartbeat_count = 0
        self.last_heartbeat_time = 0.0
        self.latest_phone_location: tuple[float | None, float | None] = (None, None)
        default_name = f"SmartCane-{socket.gethostname()}"
        self.device_name = self._current_device_name(default_name)
        self.device_id = os.getenv("SMARTCANE_DEVICE_ID", socket.gethostname())

    def current_identity(self) -> tuple[str, str]:
        self.device_name = self._current_device_name(self.device_name)
        self.device_id = os.getenv("SMARTCANE_DEVICE_ID", self.device_id)
        return self.device_name, self.device_id

    async def handler(self, websocket: WebSocketServerProtocol) -> None:
        self.clients.add(websocket)
        diagnostics_state.set_connected_clients(len(self.clients))
        diagnostics_state.set_stage("AC")
        logger.info("App client connected from %s", websocket.remote_address)
        pair_hello_received = asyncio.Event()
        pair_watchdog = asyncio.create_task(self._pair_watchdog(pair_hello_received))
        try:
            async for message in websocket:
                payload = self._parse_message(message)
                if payload is None:
                    diagnostics_state.set_error("JM")
                    logger.warning("Dropped malformed message from app")
                    continue

                payload_type = payload.get("type")
                logger.debug("Received app payload type=%s payload=%s", payload_type, payload)
                if payload_type == "DISCRETE_CMD":
                    diagnostics_state.set_stage("CM")
                    self.latest_discrete_command = payload.get("command", "STOP")
                    self.latest_instruction_text = payload.get("instructionText", "")
                    logger.info(
                        "Updated discrete command to %s (%s)",
                        self.latest_discrete_command,
                        self.latest_instruction_text,
                    )
                elif payload_type == "HEARTBEAT":
                    self.heartbeat_count += 1
                    self.last_heartbeat_time = time.monotonic()
                    self.latest_phone_location = (
                        payload.get("latitude"),
                        payload.get("longitude"),
                    )
                    logger.debug(
                        "Heartbeat #%s from phone, location=%s",
                        self.heartbeat_count,
                        self.latest_phone_location,
                    )
                    diagnostics_state.set_stage("HB")
                elif payload_type == "DEBUG_PING":
                    diagnostics_state.set_stage("DP")
                    response = {
                        "type": "DEBUG_PONG",
                        "timestampMs": int(time.time() * 1000),
                        "echo": payload.get("debugLabel"),
                    }
                    logger.info("Responding to DEBUG_PING echo=%s", response["echo"])
                    await websocket.send(json.dumps(response))
                elif payload_type == "PAIR_HELLO":
                    pair_hello_received.set()
                    diagnostics_state.set_stage("PR")
                    self.device_name, self.device_id = self.current_identity()
                    response = {
                        "type": "PAIR_INFO",
                        "protocolVersion": 1,
                        "timestampMs": int(time.time() * 1000),
                        "deviceID": self.device_id,
                        "deviceName": self.device_name,
                        "wsPath": "/ws",
                    }
                    logger.info(
                        "Responding to PAIR_HELLO from %s with device=%s (%s)",
                        payload.get("clientName"),
                        self.device_name,
                        self.device_id,
                    )
                    await websocket.send(json.dumps(response))
                    diagnostics_state.set_stage("PT")
                elif payload_type == "AP_TEST_CONFIRM":
                    diagnostics_state.set_stage("CF")
                    self._confirm_ap_test(payload.get("clientName"))
        finally:
            pair_watchdog.cancel()
            self.clients.discard(websocket)
            diagnostics_state.set_connected_clients(len(self.clients))
            diagnostics_state.set_stage("DC")
            logger.info("App client disconnected: %s", websocket.remote_address)

    async def broadcast_telemetry(self, payload: dict[str, Any]) -> None:
        if not self.clients:
            return

        text = json.dumps(payload)
        logger.debug("Broadcasting %s to %s client(s)", payload.get("type"), len(self.clients))
        await asyncio.gather(
            *(client.send(text) for client in self.clients), return_exceptions=True
        )

    def telemetry_payload(
        self,
        obstacle_distance_cm: float,
        motor_imu_available: bool,
        motor_imu_heading_degrees: float | None,
        motor_imu_pitch_degrees: float | None,
        motor_imu_roll_degrees: float | None,
        handle_imu_available: bool,
        handle_imu_heading_degrees: float,
        handle_imu_gyro_z_dps: float,
        gps_fix_status: str,
        fault_code: str,
        status_message: str,
    ) -> dict[str, Any]:
        return {
            "type": "TELEMETRY",
            "protocolVersion": 1,
            "timestampMs": int(time.time() * 1000),
            "obstacleDistanceCm": obstacle_distance_cm,
            # Explicit two-IMU telemetry:
            # - motor IMU lives on ESP32 and should be used for motor-unit heading.
            # - handle IMU lives on Pi and is for camera deblur/stabilization.
            "motorImuAvailable": motor_imu_available,
            "motorImuHeadingDegrees": motor_imu_heading_degrees,
            "motorImuPitchDegrees": motor_imu_pitch_degrees,
            "motorImuRollDegrees": motor_imu_roll_degrees,
            "handleImuAvailable": handle_imu_available,
            "handleImuHeadingDegrees": handle_imu_heading_degrees,
            "handleImuGyroZDegreesPerSecond": handle_imu_gyro_z_dps,
            # Legacy field kept for older clients until they migrate.
            "headingDegrees": motor_imu_heading_degrees,
            "gpsFixStatus": gps_fix_status,
            "faultCode": fault_code,
            "statusMessage": status_message,
        }

    @staticmethod
    def _parse_message(message: Any) -> dict[str, Any] | None:
        if isinstance(message, bytes):
            message = message.decode("utf-8", errors="ignore")

        try:
            return json.loads(message)
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _current_device_name(default_name: str) -> str:
        if DEVICE_NAME_PATH.exists():
            return DEVICE_NAME_PATH.read_text().strip() or default_name
        return os.getenv("SMARTCANE_DEVICE_NAME", default_name)

    @staticmethod
    async def _pair_watchdog(pair_hello_received: asyncio.Event) -> None:
        try:
            await asyncio.wait_for(pair_hello_received.wait(), timeout=4.0)
        except asyncio.TimeoutError:
            diagnostics_state.set_error("WT")
            diagnostics_state.set_stage("PW")
        except asyncio.CancelledError:
            pass

    @staticmethod
    def _confirm_ap_test(client_name: Any) -> None:
        if not NETWORK_SCRIPT.exists():
            diagnostics_state.set_error("NS")
            logger.warning("Cannot confirm AP test because %s is missing", NETWORK_SCRIPT)
            return

        try:
            result = subprocess.run(
                ["sudo", str(NETWORK_SCRIPT), "confirm-test"],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                diagnostics_state.set_stage("CF")
                logger.info(
                    "Confirmed AP test from app client %s: %s",
                    client_name,
                    (result.stdout or "").strip() or "ok",
                )
            else:
                diagnostics_state.set_error("RC")
                logger.warning(
                    "AP test confirm failed for app client %s: %s",
                    client_name,
                    (result.stderr or result.stdout or "").strip(),
                )
        except Exception as exc:
            diagnostics_state.set_error("EX")
            logger.warning("AP test confirm raised %s", exc)
