import logging
import os
import shutil
import subprocess
import time

from diagnostics_state import diagnostics_state
from network_manager import get_status

logger = logging.getLogger(__name__)


class BluetoothDiagnosticsBeacon:
    def __init__(self) -> None:
        self.enabled = os.getenv("SMARTCANE_BLE_DIAGNOSTICS", "1") != "0"
        self.available = shutil.which("bluetoothctl") is not None
        self._last_advertised_name: str | None = None
        self._last_publish_at = 0.0
        self._warned_unavailable = False
        self._page_index = 0

    def update_runtime_state(self, fault_code: str, connected_clients: int, runtime_active: bool) -> None:
        diagnostics_state.set_connected_clients(connected_clients)
        diagnostics_state.set_runtime_active(runtime_active)
        if fault_code and fault_code != "NONE":
            diagnostics_state.set_error(self._short_fault_code(fault_code))

    def publish(self, force: bool = False) -> None:
        if not self.enabled:
            return

        if not self.available:
            if not self._warned_unavailable:
                logger.warning("BLE diagnostics unavailable because bluetoothctl is not installed")
                self._warned_unavailable = True
            return

        advertised_name = self._build_advertised_name()
        now = time.monotonic()
        if not force and advertised_name == self._last_advertised_name and now - self._last_publish_at < 10:
            return

        commands = [
            "power on",
            "pairable on",
            "discoverable on",
            f"system-alias {advertised_name}",
            "menu advertise",
            "name on",
            "discoverable on",
            "back",
            "advertise on",
            "quit",
        ]

        try:
            result = subprocess.run(
                ["bluetoothctl"],
                input="\n".join(commands) + "\n",
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                self._last_advertised_name = advertised_name
                self._last_publish_at = now
                logger.debug("Published BLE diagnostics beacon %s", advertised_name)
            else:
                logger.warning(
                    "Failed to publish BLE diagnostics beacon %s: %s",
                    advertised_name,
                    (result.stderr or result.stdout or "").strip(),
                )
        except Exception as exc:
            logger.warning("BLE diagnostics publish failed: %s", exc)

    def stop(self) -> None:
        if not self.enabled or not self.available:
            return

        try:
            subprocess.run(
                ["bluetoothctl"],
                input="advertise off\nquit\n",
                check=False,
                capture_output=True,
                text=True,
            )
        except Exception as exc:
            logger.warning("BLE diagnostics shutdown failed: %s", exc)

    def _build_advertised_name(self) -> str:
        network = get_status()
        snapshot = diagnostics_state.snapshot()
        mode_code = {
            "PHONE_HOTSPOT_CLIENT": "H",
            "PI_ACCESS_POINT": "A",
            "UNCONFIGURED": "N",
        }.get(str(network["mode"]), "N")
        wifi_client_active = int(bool(network["client_active"]))
        runtime_flag = int(bool(snapshot["runtime_active"]))
        client_flag = int(int(snapshot["connected_clients"]) > 0)
        stage_code = str(snapshot["stage_code"])
        error_code = str(snapshot["last_error_code"])
        recent_codes = "".join(str(code) for code in list(snapshot["recent_codes"])[-5:])
        runtime_ip = str(network["runtime_ip"] or "")
        ip_hex = self._encode_ipv4(runtime_ip)

        self._page_index = (self._page_index + 1) % 2
        if self._page_index == 0:
            return f"SC0M{mode_code}R{runtime_flag}W{wifi_client_active}C{client_flag}P{stage_code}E{error_code}I{ip_hex}"

        return f"SC1{recent_codes}"

    @staticmethod
    def _encode_ipv4(ip_address: str) -> str:
        parts = ip_address.split(".")
        if len(parts) != 4:
            return "00000000"
        try:
            return "".join(f"{int(part):02X}" for part in parts)
        except ValueError:
            return "00000000"

    @staticmethod
    def _short_fault_code(fault_code: str) -> str:
        mapping = {
            "NONE": "NO",
            "HEARTBEAT_TIMEOUT": "HT",
            "ULTRASONIC_FAULT": "UF",
            "GPS_UNAVAILABLE": "GU",
            "IMU_UNAVAILABLE": "IU",
            "HANDLE_IMU_UNAVAILABLE": "HI",
            "MOTOR_IMU_UNAVAILABLE": "MI",
            "MOTOR_DRIVER_FAULT": "MD",
        }
        return mapping.get(fault_code, "XX")
