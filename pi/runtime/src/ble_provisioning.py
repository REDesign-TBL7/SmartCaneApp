import asyncio
import json
import logging
import subprocess
import time
from typing import Awaitable, Callable

from diagnostics_state import diagnostics_state

try:
    from dbus_next import DBusError, Variant
    from dbus_next.aio import MessageBus
    from dbus_next.constants import BusType, PropertyAccess
    from dbus_next.service import ServiceInterface, dbus_property, method
except ModuleNotFoundError:  # pragma: no cover - depends on Pi image packages
    DBusError = None
    Variant = None
    MessageBus = None
    BusType = None
    class _PropertyAccessFallback:
        READ = "read"

    PropertyAccess = _PropertyAccessFallback()
    ServiceInterface = object
    def dbus_property(*args, **kwargs):  # type: ignore[no-redef]
        def decorator(func):
            return property(func)

        return decorator

    def method(*args, **kwargs):  # type: ignore[no-redef]
        def decorator(func):
            return func

        return decorator

logger = logging.getLogger(__name__)

SERVICE_UUID = "7d0d1000-6a6e-4b2d-9b5f-8f5f7f51a001"
CREDENTIALS_UUID = "7d0d1001-6a6e-4b2d-9b5f-8f5f7f51a001"
STATUS_UUID = "7d0d1002-6a6e-4b2d-9b5f-8f5f7f51a001"
APP_PATH = "/org/smartcane/provision"
ADAPTER_PATH = "/org/bluez/hci0"
ADVERTISEMENT_PATH = "/org/smartcane/provision/advertisement0"


def is_available() -> bool:
    return MessageBus is not None


def _run_best_effort(cmd: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(
            cmd,
            input=input_text,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return None


def _is_bluetooth_soft_blocked() -> bool:
    result = _run_best_effort(["rfkill", "list", "bluetooth"])
    if result is None or result.returncode != 0:
        return False
    return "Soft blocked: yes" in result.stdout


class ProvisioningApplication(ServiceInterface):
    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        apply_credentials: Callable[[str, str], Awaitable[bool]],
        status_provider: Callable[[], dict[str, object]],
    ) -> None:
        super().__init__("org.freedesktop.DBus.ObjectManager")
        self.loop = loop
        self.path = APP_PATH
        self.apply_credentials = apply_credentials
        self.status_provider = status_provider
        self.status_payload: dict[str, object] = {
            "phase": "BLE_READY",
            "message": "Waiting for hotspot credentials",
        }
        self.service = ProvisioningService(self)
        self.credentials_characteristic = CredentialsCharacteristic(self.service, self)
        self.status_characteristic = StatusCharacteristic(self.service, self)
        self.service.characteristics = [
            self.credentials_characteristic,
            self.status_characteristic,
        ]

    @method()
    def GetManagedObjects(self) -> "a{oa{sa{sv}}}":
        return {
            self.service.path: {
                "org.bluez.GattService1": self.service.properties(),
            },
            self.credentials_characteristic.path: {
                "org.bluez.GattCharacteristic1": self.credentials_characteristic.properties(),
            },
            self.status_characteristic.path: {
                "org.bluez.GattCharacteristic1": self.status_characteristic.properties(),
            },
        }

    def update_status(self, phase: str, message: str) -> None:
        self.status_payload = {
            "phase": phase,
            "message": message,
        }
        self.status_characteristic.refresh_value()

    def current_status_bytes(self) -> bytes:
        snapshot = self.status_provider()
        recent_messages = list(snapshot.get("recent_messages") or [])[-6:]
        payload = {
            **self.status_payload,
            "networkMode": snapshot.get("mode"),
            "runtimeIP": snapshot.get("runtime_ip"),
            "hotspotSSID": snapshot.get("hotspot_ssid"),
            "fallbackHotspotSSID": snapshot.get("fallback_hotspot_ssid"),
            "configuredNetworks": snapshot.get("configured_networks"),
            "hotspotSources": snapshot.get("hotspot_sources"),
            "clientActive": snapshot.get("client_active"),
            "connectedSSID": snapshot.get("connected_ssid"),
            "lastConnectedSSID": snapshot.get("last_connected_ssid"),
            "lastAttemptedSSID": snapshot.get("last_attempted_ssid"),
            "lastFailureReason": snapshot.get("last_failure_reason"),
            "missingPackages": snapshot.get("missing_packages"),
            "runtimeActive": snapshot.get("runtime_active"),
            "stage": snapshot.get("stage_code"),
            "error": snapshot.get("last_error_code"),
            "recentMessages": recent_messages,
        }
        return json.dumps(payload, separators=(",", ":")).encode("utf-8")

    def schedule_credentials_write(self, raw_value: bytes) -> None:
        self.loop.create_task(self._handle_credentials_write(raw_value))

    async def _handle_credentials_write(self, raw_value: bytes) -> None:
        try:
            payload = json.loads(raw_value.decode("utf-8"))
        except Exception:
            diagnostics_state.set_error("BJ")
            self.update_status("INVALID_JSON", "BLE credentials payload is not valid JSON")
            return

        ssid = str(payload.get("hotspotSSID") or payload.get("ssid") or "").strip()
        password = str(payload.get("hotspotPassword") or payload.get("password") or "").strip()
        if not ssid or not password:
            diagnostics_state.set_error("BC")
            self.update_status("INVALID_PAYLOAD", "BLE credentials must include hotspotSSID and hotspotPassword")
            return

        diagnostics_state.set_stage("PS")
        diagnostics_state.set_error("NO")
        diagnostics_state.add_message(f"BLE received hotspot credentials for {ssid}")
        self.update_status("CREDENTIALS_SAVED", f"Saved credentials for {ssid}, joining hotspot")

        diagnostics_state.set_stage("PJ")
        self.update_status("JOINING_HOTSPOT", f"Joining hotspot {ssid}")
        success = await self.apply_credentials(ssid, password)
        if success:
            diagnostics_state.set_error("NO")
            diagnostics_state.set_stage("NR")
            self.update_status("HOTSPOT_CONNECTED", f"Joined hotspot {ssid}")
        else:
            diagnostics_state.set_error("HC")
            self.update_status("HOTSPOT_FAILED", f"Failed to join hotspot {ssid}")


class ProvisioningService(ServiceInterface):
    def __init__(self, application: ProvisioningApplication) -> None:
        super().__init__("org.bluez.GattService1")
        self.application = application
        self.path = f"{APP_PATH}/service0"
        self.characteristics: list[BaseCharacteristic] = []

    def properties(self) -> dict[str, Variant]:
        return {
            "UUID": Variant("s", SERVICE_UUID),
            "Primary": Variant("b", True),
            "Characteristics": Variant("ao", [characteristic.path for characteristic in self.characteristics]),
        }

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return SERVICE_UUID

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def Characteristics(self) -> "ao":
        return [characteristic.path for characteristic in self.characteristics]


class BaseCharacteristic(ServiceInterface):
    def __init__(self, uuid: str, index: int, flags: list[str], service: ProvisioningService) -> None:
        super().__init__("org.bluez.GattCharacteristic1")
        self.uuid = uuid
        self.flags = flags
        self.service = service
        self.path = f"{service.path}/char{index}"
        self.value: list[int] = []

    def properties(self) -> dict[str, Variant]:
        return {
            "Service": Variant("o", self.service.path),
            "UUID": Variant("s", self.uuid),
            "Flags": Variant("as", self.flags),
            "Value": Variant("ay", self.value),
        }

    def refresh_value(self) -> None:
        pass

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> "s":
        return self.uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> "o":
        return self.service.path

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> "as":
        return self.flags

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> "ay":
        return self.value

    @method()
    def ReadValue(self, options: "a{sv}") -> "ay":
        self.refresh_value()
        return self.value

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}") -> None:
        raise DBusError("org.bluez.Error.NotSupported", "Write not supported")


class CredentialsCharacteristic(BaseCharacteristic):
    def __init__(self, service: ProvisioningService, application: ProvisioningApplication) -> None:
        super().__init__(CREDENTIALS_UUID, 0, ["write", "write-without-response"], service)
        self.application = application

    @method()
    def WriteValue(self, value: "ay", options: "a{sv}") -> None:
        self.value = list(value)
        self.application.schedule_credentials_write(bytes(value))


class StatusCharacteristic(BaseCharacteristic):
    def __init__(self, service: ProvisioningService, application: ProvisioningApplication) -> None:
        super().__init__(STATUS_UUID, 1, ["read"], service)
        self.application = application
        self.refresh_value()

    def refresh_value(self) -> None:
        self.value = list(self.application.current_status_bytes())


class ProvisioningAdvertisement(ServiceInterface):
    def __init__(self, local_name: str = "SmartCane BLE") -> None:
        super().__init__("org.bluez.LEAdvertisement1")
        self.path = ADVERTISEMENT_PATH
        self.local_name = local_name

    def properties(self) -> dict[str, Variant]:
        return {
            "Type": Variant("s", "peripheral"),
            "ServiceUUIDs": Variant("as", [SERVICE_UUID]),
            "LocalName": Variant("s", self.local_name),
            "Discoverable": Variant("b", True),
        }

    @dbus_property(access=PropertyAccess.READ)
    def Type(self) -> "s":
        return "peripheral"

    @dbus_property(access=PropertyAccess.READ)
    def ServiceUUIDs(self) -> "as":
        return [SERVICE_UUID]

    @dbus_property(access=PropertyAccess.READ)
    def LocalName(self) -> "s":
        return self.local_name

    @dbus_property(access=PropertyAccess.READ)
    def Discoverable(self) -> "b":
        return True

    @method()
    def Release(self) -> None:
        return None


class BluetoothProvisioningService:
    def __init__(
        self,
        apply_credentials: Callable[[str, str], Awaitable[bool]],
        status_provider: Callable[[], dict[str, object]],
    ) -> None:
        self.apply_credentials = apply_credentials
        self.status_provider = status_provider
        self.bus: MessageBus | None = None
        self.application: ProvisioningApplication | None = None
        self.advertisement: ProvisioningAdvertisement | None = None
        self.started = False

    async def start(self) -> bool:
        if not is_available():
            logger.warning("BLE provisioning unavailable because dbus-next is not installed")
            diagnostics_state.set_error("BP")
            return False

        try:
            await asyncio.to_thread(self._prepare_adapter)
            self.bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
            self.application = ProvisioningApplication(asyncio.get_running_loop(), self.apply_credentials, self.status_provider)

            self.bus.export(self.application.path, self.application)
            self.bus.export(self.application.service.path, self.application.service)
            self.bus.export(self.application.credentials_characteristic.path, self.application.credentials_characteristic)
            self.bus.export(self.application.status_characteristic.path, self.application.status_characteristic)
            self.advertisement = ProvisioningAdvertisement()
            self.bus.export(self.advertisement.path, self.advertisement)

            bluez_object = await self.bus.introspect("org.bluez", ADAPTER_PATH)
            adapter = self.bus.get_proxy_object("org.bluez", ADAPTER_PATH, bluez_object)
            manager = adapter.get_interface("org.bluez.GattManager1")
            advertising_manager = adapter.get_interface("org.bluez.LEAdvertisingManager1")
            await manager.call_register_application(self.application.path, {})
            await advertising_manager.call_register_advertisement(self.advertisement.path, {})
            self.application.update_status("BLE_READY", "Waiting for hotspot credentials")
            diagnostics_state.set_stage("PV")
            self.started = True
            logger.info("BLE provisioning service registered on %s", ADAPTER_PATH)
            return True
        except Exception as exc:
            diagnostics_state.set_error("BP")
            logger.warning("Failed to start BLE provisioning service: %s", exc)
            return False

    async def stop(self) -> None:
        if not self.started or self.bus is None or self.application is None:
            return

        try:
            bluez_object = await self.bus.introspect("org.bluez", ADAPTER_PATH)
            adapter = self.bus.get_proxy_object("org.bluez", ADAPTER_PATH, bluez_object)
            manager = adapter.get_interface("org.bluez.GattManager1")
            advertising_manager = adapter.get_interface("org.bluez.LEAdvertisingManager1")
            if self.advertisement is not None:
                await advertising_manager.call_unregister_advertisement(self.advertisement.path)
            await manager.call_unregister_application(self.application.path)
        except Exception:
            logger.debug("BLE provisioning unregister failed", exc_info=True)
        self.started = False

    @staticmethod
    def _prepare_adapter() -> None:
        diagnostics_state.add_message("Preparing Bluetooth adapter")
        _run_best_effort(["rfkill", "unblock", "bluetooth"])
        _run_best_effort(["systemctl", "start", "bluetooth"])

        for _ in range(4):
            _run_best_effort(
                ["bluetoothctl"],
                input_text="power on\npairable on\ndiscoverable on\nquit\n",
            )
            if not _is_bluetooth_soft_blocked():
                diagnostics_state.add_message("Bluetooth adapter ready")
                return
            time.sleep(1)

        diagnostics_state.set_error("RB")
        diagnostics_state.add_message("Bluetooth is still soft-blocked after rfkill unblock")
        logger.warning("Bluetooth adapter is still soft-blocked after preparation")
