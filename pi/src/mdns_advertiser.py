import logging
import os
import re
import socket
from typing import Any

logger = logging.getLogger(__name__)

try:
    from zeroconf import IPVersion, ServiceInfo, Zeroconf
except ImportError:  # pragma: no cover - optional dependency at runtime
    Zeroconf = None  # type: ignore[assignment]
    ServiceInfo = None  # type: ignore[assignment]
    IPVersion = None  # type: ignore[assignment]


class MDNSAdvertiser:
    """Publishes the Pi WebSocket service over mDNS/Bonjour."""

    def __init__(self, device_name: str, device_id: str, port: int = 8080) -> None:
        self.device_name = device_name
        self.device_id = device_id
        self.port = port
        self.service_type = "_smartcane._tcp.local."
        self.zeroconf: Zeroconf | None = None
        self.service_info: ServiceInfo | None = None

    def start(self) -> None:
        if Zeroconf is None or ServiceInfo is None or IPVersion is None:
            logger.warning("zeroconf package not installed, skipping mDNS advertisement")
            return

        addresses = self._ipv4_addresses()
        if not addresses:
            logger.warning("Could not determine a non-loopback IPv4 address for mDNS advertisement")
            return

        server_host = f"{self._sanitized_hostname()}.local."
        instance_name = f"{self.device_name}.{self.service_type}"
        properties: dict[str | bytes, str | bytes | Any] = {
            b"device_id": self.device_id.encode("utf-8"),
            b"device_name": self.device_name.encode("utf-8"),
            b"ws_path": b"/ws",
        }

        self.zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
        self.service_info = ServiceInfo(
            type_=self.service_type,
            name=instance_name,
            addresses=[socket.inet_aton(address) for address in addresses],
            port=self.port,
            properties=properties,
            server=server_host,
        )

        self.zeroconf.register_service(self.service_info)
        logger.info(
            "Published mDNS service %s on %s:%s",
            instance_name,
            ", ".join(addresses),
            self.port,
        )

    def stop(self) -> None:
        if self.zeroconf is None or self.service_info is None:
            return

        try:
            self.zeroconf.unregister_service(self.service_info)
            logger.info("Stopped mDNS advertisement for %s", self.device_name)
        finally:
            self.zeroconf.close()
            self.zeroconf = None
            self.service_info = None

    @staticmethod
    def _sanitized_hostname() -> str:
        base_name = os.getenv("SMARTCANE_MDNS_HOSTNAME", socket.gethostname())
        sanitized = re.sub(r"[^A-Za-z0-9-]", "-", base_name).strip("-").lower()
        return sanitized or "smartcane-pi"

    @staticmethod
    def _ipv4_addresses() -> list[str]:
        addresses: list[str] = []

        try:
            host_addresses = socket.gethostbyname_ex(socket.gethostname())[2]
            addresses.extend(host_addresses)
        except OSError:
            pass

        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect(("172.20.10.1", 9))
                addresses.append(sock.getsockname()[0])
        except OSError:
            pass

        unique_addresses: list[str] = []
        for address in addresses:
            if address.startswith("127."):
                continue
            if address not in unique_addresses:
                unique_addresses.append(address)

        return unique_addresses
