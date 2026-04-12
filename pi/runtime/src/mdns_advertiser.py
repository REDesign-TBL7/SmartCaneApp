import ipaddress
import logging
from dataclasses import dataclass

from zeroconf import IPVersion, ServiceInfo, Zeroconf

logger = logging.getLogger(__name__)

SERVICE_TYPE = "_smartcane._tcp.local."


@dataclass(frozen=True)
class RuntimeAdvertisement:
    host: str
    port: int
    path: str
    device_name: str
    device_id: str


class RuntimeServiceAdvertiser:
    def __init__(self) -> None:
        self._zeroconf: Zeroconf | None = None
        self._service_info: ServiceInfo | None = None
        self._registered = False

    def start(self, advertisement: RuntimeAdvertisement) -> bool:
        try:
            address = ipaddress.ip_address(advertisement.host)
        except ValueError:
            logger.warning("Skipping mDNS advertisement because host is not an IP address: %s", advertisement.host)
            return False

        properties = {
            b"path": advertisement.path.encode("utf-8"),
            b"deviceID": advertisement.device_id.encode("utf-8"),
            b"deviceName": advertisement.device_name.encode("utf-8"),
        }
        instance_name = self._normalized_instance_name(advertisement.device_name)
        service_name = f"{instance_name}.{SERVICE_TYPE}"
        server_name = f"{self._normalized_host_label(advertisement.device_name)}.local."

        zeroconf = Zeroconf(ip_version=IPVersion.All)
        info = ServiceInfo(
            type_=SERVICE_TYPE,
            name=service_name,
            addresses=[address.packed],
            port=advertisement.port,
            properties=properties,
            server=server_name,
        )

        try:
            zeroconf.register_service(info)
        except Exception:
            zeroconf.close()
            raise

        self._zeroconf = zeroconf
        self._service_info = info
        self._registered = True
        logger.info(
            "Registered mDNS service %s at %s:%s%s",
            service_name,
            advertisement.host,
            advertisement.port,
            advertisement.path,
        )
        return True

    def stop(self) -> None:
        if not self._registered or self._zeroconf is None or self._service_info is None:
            return
        try:
            self._zeroconf.unregister_service(self._service_info)
        except Exception:
            logger.debug("mDNS unregister failed", exc_info=True)
        finally:
            self._zeroconf.close()
            self._zeroconf = None
            self._service_info = None
            self._registered = False

    @staticmethod
    def _normalized_instance_name(device_name: str) -> str:
        cleaned = "".join(ch for ch in device_name.strip() if ch.isalnum() or ch in {" ", "-", "_"})
        return cleaned or "SmartCane"

    @staticmethod
    def _normalized_host_label(device_name: str) -> str:
        cleaned = "".join(ch.lower() if ch.isalnum() else "-" for ch in device_name.strip())
        while "--" in cleaned:
            cleaned = cleaned.replace("--", "-")
        cleaned = cleaned.strip("-")
        return cleaned or "smartcane-pi"
