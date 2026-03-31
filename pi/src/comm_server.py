import asyncio
import json
import time
from typing import Any

from websockets.server import WebSocketServerProtocol


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
        try:
            async for message in websocket:
                payload = self._parse_message(message)
                if payload is None:
                    continue

                payload_type = payload.get("type")
                if payload_type == "DISCRETE_CMD":
                    self.latest_discrete_command = payload.get("command", "STOP")
                    self.latest_instruction_text = payload.get("instructionText", "")
                elif payload_type == "HEARTBEAT":
                    self.heartbeat_count += 1
                    self.last_heartbeat_time = time.monotonic()
                    self.latest_phone_location = (
                        payload.get("latitude"),
                        payload.get("longitude"),
                    )
        finally:
            self.clients.discard(websocket)

    async def broadcast_telemetry(self, payload: dict[str, Any]) -> None:
        if not self.clients:
            return

        text = json.dumps(payload)
        await asyncio.gather(
            *(client.send(text) for client in self.clients), return_exceptions=True
        )

    def telemetry_payload(
        self,
        battery_percentage: int,
        obstacle_distance_cm: float,
        heading_degrees: float,
        gps_fix_status: str,
        fault_code: str,
    ) -> dict[str, Any]:
        return {
            "type": "TELEMETRY",
            "protocolVersion": 1,
            "timestampMs": int(time.time() * 1000),
            "batteryPercentage": battery_percentage,
            "obstacleDistanceCm": obstacle_distance_cm,
            "headingDegrees": heading_degrees,
            "gpsFixStatus": gps_fix_status,
            "faultCode": fault_code,
            "statusMessage": "Pi runtime active",
        }

    @staticmethod
    def _parse_message(message: Any) -> dict[str, Any] | None:
        if isinstance(message, bytes):
            message = message.decode("utf-8", errors="ignore")

        try:
            return json.loads(message)
        except json.JSONDecodeError:
            return None
