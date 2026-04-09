import json
import logging
import os
import subprocess
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parents[2]
HOTSPOT_SCRIPT = REPO_ROOT / "infra" / "pi-network" / "setup_hotspot_client_mode.sh"
DEVICE_NAME_PATH = Path("/etc/smartcane/device_name")
SETUP_CONFIG_PATH = Path("/etc/smartcane/onboarding.json")


class SetupState:
    def __init__(self) -> None:
        default_device_name = f"SmartCane-{os.uname().nodename}"
        self.device_id = os.getenv("SMARTCANE_DEVICE_ID", os.uname().nodename)
        self.device_name = DEVICE_NAME_PATH.read_text().strip() if DEVICE_NAME_PATH.exists() else os.getenv("SMARTCANE_DEVICE_NAME", default_device_name)
        self.last_setup_status = "idle"

    def setup_status_payload(self) -> dict[str, Any]:
        return {
            "deviceID": self.device_id,
            "deviceName": self.device_name,
            "setupSSID": os.getenv("SMARTCANE_SETUP_SSID", "SmartCaneSetup"),
            "setupStatus": self.last_setup_status,
        }

    def update_device_name(self, new_name: str) -> None:
        normalized = new_name.strip()
        if not normalized:
            return
        self.device_name = normalized
        DEVICE_NAME_PATH.parent.mkdir(parents=True, exist_ok=True)
        DEVICE_NAME_PATH.write_text(normalized)


class SetupHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], handler_class: type[BaseHTTPRequestHandler], state: SetupState) -> None:
        super().__init__(server_address, handler_class)
        self.state = state


class SetupRequestHandler(BaseHTTPRequestHandler):
    server: SetupHTTPServer

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/setup/status":
            self._respond_json({"error": "not_found"}, status=HTTPStatus.NOT_FOUND)
            return

        self._respond_json(self.server.state.setup_status_payload())

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/setup/hotspot":
            self._respond_json({"error": "not_found"}, status=HTTPStatus.NOT_FOUND)
            return

        body = self._read_json()
        if body is None:
            self._respond_json({"error": "invalid_json"}, status=HTTPStatus.BAD_REQUEST)
            return

        hotspot_ssid = str(body.get("hotspotSSID", "")).strip()
        hotspot_password = str(body.get("hotspotPassword", "")).strip()
        device_name = str(body.get("deviceName", "")).strip()

        if not hotspot_ssid or not hotspot_password:
            self._respond_json(
                {"error": "missing_credentials"},
                status=HTTPStatus.BAD_REQUEST,
            )
            return

        if device_name:
            self.server.state.update_device_name(device_name)

        self.server.state.last_setup_status = "applying_hotspot_credentials"
        self._persist_setup_request(hotspot_ssid, device_name)
        self._respond_json(
            {
                "accepted": True,
                "deviceID": self.server.state.device_id,
                "deviceName": self.server.state.device_name,
            }
        )

        timer = threading.Timer(
            1.0,
            self._apply_hotspot_configuration,
            args=(hotspot_ssid, hotspot_password),
        )
        timer.daemon = True
        timer.start()

    def log_message(self, format: str, *args: object) -> None:
        logger.debug("Setup server: " + format, *args)

    def _read_json(self) -> dict[str, Any] | None:
        content_length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(content_length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return None

    def _respond_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _persist_setup_request(self, hotspot_ssid: str, device_name: str) -> None:
        SETUP_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "hotspotSSID": hotspot_ssid,
            "deviceName": device_name or self.server.state.device_name,
            "timestampMs": int(time.time() * 1000),
        }
        SETUP_CONFIG_PATH.write_text(json.dumps(payload, indent=2))

    def _apply_hotspot_configuration(self, hotspot_ssid: str, hotspot_password: str) -> None:
        try:
            logger.info("Applying hotspot credentials for SSID=%s", hotspot_ssid)
            subprocess.run(
                [
                    "sudo",
                    str(HOTSPOT_SCRIPT),
                    "--ssid",
                    hotspot_ssid,
                    "--psk",
                    hotspot_password,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.server.state.last_setup_status = "hotspot_applied"
            logger.info("Hotspot configuration applied successfully")
        except subprocess.CalledProcessError as exc:
            self.server.state.last_setup_status = "hotspot_apply_failed"
            logger.error("Hotspot setup failed: %s", exc.stderr or exc.stdout or exc)


def start_setup_server(host: str = "0.0.0.0", port: int = 8081) -> tuple[SetupHTTPServer, threading.Thread]:
    state = SetupState()
    server = SetupHTTPServer((host, port), SetupRequestHandler, state)
    thread = threading.Thread(target=server.serve_forever, name="smartcane-setup-server", daemon=True)
    thread.start()
    logger.info("Setup HTTP server listening on %s:%s", host, port)
    return server, thread
