import asyncio
import json
import logging
import time
from typing import Any

from websockets.server import WebSocketServerProtocol

logger = logging.getLogger(__name__)


class CommServer:
    def __init__(self) -> None:
        self.clients: set[WebSocketServerProtocol] = set()
        self.latest_discrete_command = "STOP"
        self.latest_instruction_text = "No instruction"
        self.heartbeat_count = 0
        self.last_heartbeat_time = 0.0
        self.latest_phone_location: tuple[float | None, float | None] = (None, None)

    async def handler(self, websocket: WebSocketServerProtocol) -> None:
        self.clients.add(websocket)
        logger.info("App client connected from %s", websocket.remote_address)
        try:
            async for message in websocket:
                payload = self._parse_message(message)
                if payload is None:
                    logger.warning("Dropped malformed message from app")
                    continue

                payload_type = payload.get("type")
                logger.debug("Received app payload type=%s payload=%s", payload_type, payload)
                if payload_type == "DISCRETE_CMD":
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
                elif payload_type == "DEBUG_PING":
                    response = {
                        "type": "DEBUG_PONG",
                        "timestampMs": int(time.time() * 1000),
                        "echo": payload.get("debugLabel"),
                    }
                    logger.info("Responding to DEBUG_PING echo=%s", response["echo"])
                    await websocket.send(json.dumps(response))
        finally:
            self.clients.discard(websocket)
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
