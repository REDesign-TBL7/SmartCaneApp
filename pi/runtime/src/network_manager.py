import logging
import json
import os
import subprocess
import time
from pathlib import Path

from diagnostics_state import diagnostics_state

logger = logging.getLogger(__name__)

WLAN_IFACE = os.getenv("WLAN_IFACE", "wlan0")
DHCPCD_CONF = "/etc/dhcpcd.conf"
MODE_FILE = "/etc/smartcane/network_mode"
WPA_SUPPLICANT_CONF = "/etc/wpa_supplicant/wpa_supplicant.conf"
HOTSPOT_CONFIG_PATH = Path("/etc/smartcane/hotspot.json")
BOOT_CONFIG_CANDIDATES = [
    Path("/boot/firmware/smartcane-hotspot.json"),
    Path("/boot/smartcane-hotspot.json"),
]
PACKAGE_NAMES = ["iw", "rfkill", "iproute2", "dhcpcd5", "wpasupplicant", "bluez"]


def _log_diagnostic(message: str) -> None:
    diagnostics_state.add_message(message)
    logger.info(message)


def _normalize_network_entry(ssid: str, password: str, source: str) -> dict[str, str]:
    return {
        "ssid": str(ssid).strip(),
        "password": str(password).strip(),
        "source": str(source).strip() or "unknown",
    }


def normalize_hotspot_payload(payload: dict[str, object], source_hint: str) -> dict[str, object] | None:
    existing_networks = payload.get("networks")
    if isinstance(existing_networks, list):
        networks: list[dict[str, str]] = []
        for entry in existing_networks:
            if not isinstance(entry, dict):
                continue
            ssid = str(entry.get("ssid") or "").strip()
            password = str(entry.get("password") or "").strip()
            if not ssid or not password:
                continue
            networks.append(
                _normalize_network_entry(
                    ssid,
                    password,
                    str(entry.get("source") or source_hint),
                )
            )
        if networks:
            return {
                "networks": networks,
                "activeSSID": str(payload.get("activeSSID") or "").strip(),
                "lastConnectedSSID": str(payload.get("lastConnectedSSID") or "").strip(),
                "lastAttemptedSSID": str(payload.get("lastAttemptedSSID") or "").strip(),
                "lastFailureReason": str(payload.get("lastFailureReason") or "").strip(),
            }

    primary_ssid = str(payload.get("hotspotSSID") or payload.get("ssid") or "").strip()
    primary_password = str(payload.get("hotspotPassword") or payload.get("password") or "").strip()
    fallback_ssid = str(payload.get("fallbackHotspotSSID") or payload.get("fallbackSSID") or "").strip()
    fallback_password = str(payload.get("fallbackHotspotPassword") or payload.get("fallbackPassword") or "").strip()

    networks: list[dict[str, str]] = []
    if primary_ssid and primary_password:
        networks.append(
            _normalize_network_entry(
                primary_ssid,
                primary_password,
                str(payload.get("source") or source_hint),
            )
        )

    if fallback_ssid and fallback_password:
        networks.append(
            _normalize_network_entry(
                fallback_ssid,
                fallback_password,
                str(payload.get("fallbackSource") or payload.get("source") or source_hint),
            )
        )

    if not networks:
        return None

    return {
        "networks": networks,
        "activeSSID": str(payload.get("activeSSID") or "").strip(),
        "lastConnectedSSID": str(payload.get("lastConnectedSSID") or "").strip(),
        "lastAttemptedSSID": str(payload.get("lastAttemptedSSID") or "").strip(),
        "lastFailureReason": str(payload.get("lastFailureReason") or "").strip(),
    }


def run_cmd(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def is_root() -> bool:
    return os.geteuid() == 0


def check_package(pkg: str) -> bool:
    try:
        run_cmd(["dpkg", "-l", pkg])
        return True
    except subprocess.CalledProcessError:
        return False


def install_packages() -> bool:
    missing = [p for p in PACKAGE_NAMES if not check_package(p)]
    
    if not missing:
        logger.info("All required packages installed")
        return True
    
    if not is_root():
        logger.warning("Missing packages %s - need root to install", missing)
        return False
    
    logger.info("Installing packages: %s (this may take a few minutes)", missing)
    try:
        run_cmd(["apt-get", "update", "-qq"])
        run_cmd(["apt-get", "install", "-y", "-qq"] + missing)
        return True
    except subprocess.CalledProcessError as e:
        logger.error("Failed to install packages: %s", e)
        return False


def get_ipv4_address(interface: str) -> str | None:
    try:
        result = run_cmd(["ip", "-4", "addr", "show", interface], check=False)
        if result.returncode != 0:
            return None
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("inet "):
                return line.split()[1].split("/", 1)[0]
        return None
    except Exception:
        return None


def get_connected_ssid() -> str:
    try:
        result = run_cmd(["iwgetid", "-r"], check=False)
        if result.returncode != 0:
            return ""
        return result.stdout.strip()
    except Exception:
        return ""


def stop_services() -> None:
    for svc in ["hostapd", "dnsmasq"]:
        run_cmd(["systemctl", "stop", svc], check=False)
        run_cmd(["systemctl", "disable", svc], check=False)


def reset_interface() -> None:
    run_cmd(["rfkill", "unblock", "wifi"], check=False)
    run_cmd(["ip", "link", "set", WLAN_IFACE, "down"], check=False)
    run_cmd(["ip", "addr", "flush", "dev", WLAN_IFACE], check=False)
    run_cmd(["ip", "link", "set", WLAN_IFACE, "up"], check=False)
    run_cmd(["iw", "dev", WLAN_IFACE, "set", "power_save", "off"], check=False)


def remove_ap_dhcpcd_block() -> None:
    marker = "# smartcane-ap"
    content = Path(DHCPCD_CONF).read_text() if Path(DHCPCD_CONF).exists() else ""
    lines = content.splitlines()
    filtered: list[str] = []
    skipping = False
    for line in lines:
        if line == marker:
            skipping = True
            continue
        if skipping:
            if line.strip() == "":
                skipping = False
            continue
        filtered.append(line)
    Path(DHCPCD_CONF).write_text("\n".join(filtered).rstrip() + "\n")


def write_mode_file(mode: str, extra: dict[str, str] | None = None) -> None:
    Path("/etc/smartcane").mkdir(exist_ok=True)
    lines = [f"SMARTCANE_NETWORK_MODE={mode}"]
    for key, value in (extra or {}).items():
        lines.append(f"{key}={value}")
    Path(MODE_FILE).write_text("\n".join(lines) + "\n")


def write_wpa_supplicant_conf(networks: list[dict[str, str]]) -> None:
    Path(WPA_SUPPLICANT_CONF).parent.mkdir(parents=True, exist_ok=True)
    network_blocks: list[str] = []
    priority = len(networks) + 9
    for network in networks:
        network_blocks.append(
            f"""network={{
    ssid="{network["ssid"]}"
    psk="{network["password"]}"
    key_mgmt=WPA-PSK
    scan_ssid=1
    priority={priority}
}}
"""
        )
        priority -= 1

    conf = f"""ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=SG

{''.join(network_blocks)}"""
    Path(WPA_SUPPLICANT_CONF).write_text(conf)
    os.chmod(WPA_SUPPLICANT_CONF, 0o600)


def start_hotspot_client() -> None:
    _log_diagnostic("Starting hotspot client services")
    run_cmd(["systemctl", "stop", "dnsmasq"], check=False)
    run_cmd(["systemctl", "stop", "hostapd"], check=False)
    run_cmd(["systemctl", "disable", "dnsmasq"], check=False)
    run_cmd(["systemctl", "disable", "hostapd"], check=False)
    run_cmd(["systemctl", "enable", "dhcpcd"], check=False)
    run_cmd(["systemctl", "enable", "wpa_supplicant"], check=False)
    run_cmd(["systemctl", "enable", f"wpa_supplicant@{WLAN_IFACE}"], check=False)

    _log_diagnostic("Restarting dhcpcd")
    run_cmd(["systemctl", "restart", "dhcpcd"], check=False)
    time.sleep(2)

    _log_diagnostic("Restarting wpa_supplicant")
    run_cmd(["systemctl", "restart", "wpa_supplicant"], check=False)
    run_cmd(["systemctl", "restart", f"wpa_supplicant@{WLAN_IFACE}"], check=False)


def import_boot_hotspot_config() -> dict[str, object] | None:
    for path in BOOT_CONFIG_CANDIDATES:
        if not path.exists():
            continue
        try:
            payload = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            logger.warning("Ignoring invalid hotspot config %s: %s", path, exc)
            continue

        normalized = normalize_hotspot_payload(payload, str(path))
        if normalized is None:
            logger.warning("Ignoring incomplete hotspot config %s", path)
            continue

        HOTSPOT_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        HOTSPOT_CONFIG_PATH.write_text(json.dumps(normalized, indent=2))
        logger.info("Imported hotspot credentials from %s", path)
        diagnostics_state.add_message(
            "Imported hotspot config from boot with networks: "
            + ", ".join(network["ssid"] for network in normalized["networks"])
        )
        return normalized
    return None


def load_hotspot_credentials() -> dict[str, object] | None:
    imported = import_boot_hotspot_config()
    if imported:
        return imported

    if not HOTSPOT_CONFIG_PATH.exists():
        return None

    try:
        payload = json.loads(HOTSPOT_CONFIG_PATH.read_text())
    except json.JSONDecodeError as exc:
        logger.error("Invalid hotspot credentials file %s: %s", HOTSPOT_CONFIG_PATH, exc)
        return None

    return normalize_hotspot_payload(payload, str(HOTSPOT_CONFIG_PATH))


def save_hotspot_config(
    primary_ssid: str,
    primary_password: str,
    source: str = "BLE",
    fallback_ssid: str = "",
    fallback_password: str = "",
    fallback_source: str | None = None,
    last_connected_ssid: str = "",
    active_ssid: str = "",
    last_attempted_ssid: str = "",
    last_failure_reason: str = "",
) -> None:
    HOTSPOT_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, object] = {
        "hotspotSSID": primary_ssid,
        "hotspotPassword": primary_password,
        "source": source,
    }
    if fallback_ssid and fallback_password:
        payload["fallbackHotspotSSID"] = fallback_ssid
        payload["fallbackHotspotPassword"] = fallback_password
        payload["fallbackSource"] = fallback_source or source
    if active_ssid:
        payload["activeSSID"] = active_ssid
    if last_connected_ssid:
        payload["lastConnectedSSID"] = last_connected_ssid
    if last_attempted_ssid:
        payload["lastAttemptedSSID"] = last_attempted_ssid
    if last_failure_reason:
        payload["lastFailureReason"] = last_failure_reason

    HOTSPOT_CONFIG_PATH.write_text(
        json.dumps(payload, indent=2)
    )
    os.chmod(HOTSPOT_CONFIG_PATH, 0o600)


def store_hotspot_credentials(
    ssid: str,
    password: str,
    source: str = "BLE",
    fallback_ssid: str = "",
    fallback_password: str = "",
) -> None:
    existing = load_hotspot_credentials()
    preserved_fallback: dict[str, str] | None = None

    if fallback_ssid and fallback_password:
        preserved_fallback = _normalize_network_entry(fallback_ssid, fallback_password, source)
    elif existing:
        for network in existing["networks"]:
            if network["ssid"] != ssid:
                preserved_fallback = network
                break

    save_hotspot_config(
        primary_ssid=ssid,
        primary_password=password,
        source=source,
        fallback_ssid=preserved_fallback["ssid"] if preserved_fallback else "",
        fallback_password=preserved_fallback["password"] if preserved_fallback else "",
        fallback_source=preserved_fallback["source"] if preserved_fallback else None,
    )
    configured = [ssid]
    if preserved_fallback:
        configured.append(preserved_fallback["ssid"])
    diagnostics_state.add_message("Stored hotspot credentials for " + " -> ".join(configured))


def is_hotspot_client_active() -> bool:
    ip_address = get_ipv4_address(WLAN_IFACE)
    if not ip_address:
        return False
    result = run_cmd(["systemctl", "is-active", f"wpa_supplicant@{WLAN_IFACE}"], check=False)
    if result.returncode == 0:
        return True
    result = run_cmd(["systemctl", "is-active", "wpa_supplicant"], check=False)
    return result.returncode == 0


def setup_hotspot_client(do_install: bool = False) -> bool:
    if not is_root():
        logger.error("Hotspot setup requires root. Run with sudo.")
        return False

    credentials = load_hotspot_credentials()
    if credentials is None:
        logger.error("No hotspot credentials found in %s or boot config", HOTSPOT_CONFIG_PATH)
        diagnostics_state.add_message("No hotspot credentials available")
        return False

    if do_install:
        install_packages()

    networks = list(credentials["networks"])
    ssid_list = ", ".join(network["ssid"] for network in networks)
    diagnostics_state.add_message(f"Configuring Wi-Fi networks: {ssid_list}")
    stop_services()
    reset_interface()

    remove_ap_dhcpcd_block()
    write_wpa_supplicant_conf(networks)
    write_mode_file(
        "PHONE_HOTSPOT_CLIENT",
        {
            "SMARTCANE_HOTSPOT_SSID": networks[0]["ssid"],
            "SMARTCANE_FALLBACK_HOTSPOT_SSID": networks[1]["ssid"] if len(networks) > 1 else "",
        },
    )
    save_hotspot_config(
        primary_ssid=networks[0]["ssid"],
        primary_password=networks[0]["password"],
        source=networks[0]["source"],
        fallback_ssid=networks[1]["ssid"] if len(networks) > 1 else "",
        fallback_password=networks[1]["password"] if len(networks) > 1 else "",
        fallback_source=networks[1]["source"] if len(networks) > 1 else None,
        last_attempted_ssid=networks[0]["ssid"],
        last_failure_reason="",
    )
    start_hotspot_client()

    for _ in range(20):
        ip_address = get_ipv4_address(WLAN_IFACE)
        connected_ssid = get_connected_ssid()
        if is_hotspot_client_active() and ip_address and connected_ssid:
            diagnostics_state.add_message(f"Connected to {connected_ssid} with IP {ip_address}")
            save_hotspot_config(
                primary_ssid=networks[0]["ssid"],
                primary_password=networks[0]["password"],
                source=networks[0]["source"],
                fallback_ssid=networks[1]["ssid"] if len(networks) > 1 else "",
                fallback_password=networks[1]["password"] if len(networks) > 1 else "",
                fallback_source=networks[1]["source"] if len(networks) > 1 else None,
                last_connected_ssid=connected_ssid,
                active_ssid=connected_ssid,
                last_attempted_ssid=connected_ssid,
                last_failure_reason="",
            )
            return True
        time.sleep(1)

    connected_ssid = get_connected_ssid()
    failure_reason = "wpa_supplicant active without DHCP lease" if connected_ssid else "no configured network associated"
    diagnostics_state.add_message(f"Hotspot join failed: {failure_reason}")
    save_hotspot_config(
        primary_ssid=networks[0]["ssid"],
        primary_password=networks[0]["password"],
        source=networks[0]["source"],
        fallback_ssid=networks[1]["ssid"] if len(networks) > 1 else "",
        fallback_password=networks[1]["password"] if len(networks) > 1 else "",
        fallback_source=networks[1]["source"] if len(networks) > 1 else None,
        active_ssid="",
        last_attempted_ssid=connected_ssid or networks[0]["ssid"],
        last_failure_reason=failure_reason,
    )
    logger.error("Hotspot client setup failed for networks=%s", ssid_list)
    return False


def ensure_network(do_install: bool = False) -> bool:
    if is_hotspot_client_active():
        logger.info("Hotspot client already active")
        return True

    credentials = load_hotspot_credentials()
    if credentials is None:
        logger.warning("No hotspot credentials available; cannot auto-join phone hotspot")
        diagnostics_state.add_message("Network check failed: no hotspot credentials configured")
        return False

    if not is_root():
        logger.warning("Hotspot client not active and no root - run with sudo for first-time setup")
        logger.info("Run: sudo python src/main.py --setup-hotspot")
        return False

    logger.info("Hotspot client not active, setting up...")
    return setup_hotspot_client(do_install)


def get_status() -> dict:
    ip_address = get_ipv4_address(WLAN_IFACE)
    client_active = is_hotspot_client_active()
    credentials = load_hotspot_credentials()
    networks = list(credentials["networks"]) if credentials else []
    missing_packages = [package for package in PACKAGE_NAMES if not check_package(package)]
    connected_ssid = get_connected_ssid()
    status = {
        "interface": WLAN_IFACE,
        "mode": "PHONE_HOTSPOT_CLIENT" if client_active else "UNCONFIGURED",
        "hotspot_ssid": networks[0]["ssid"] if networks else "",
        "fallback_hotspot_ssid": networks[1]["ssid"] if len(networks) > 1 else "",
        "configured_networks": [network["ssid"] for network in networks],
        "hotspot_sources": [network["source"] for network in networks],
        "runtime_ip": ip_address,
        "connected_ssid": connected_ssid,
        "active_ssid": str(credentials.get("activeSSID") or "") if credentials else "",
        "last_connected_ssid": str(credentials.get("lastConnectedSSID") or "") if credentials else "",
        "last_attempted_ssid": str(credentials.get("lastAttemptedSSID") or "") if credentials else "",
        "last_failure_reason": str(credentials.get("lastFailureReason") or "") if credentials else "",
        "is_root": is_root(),
        "packages_installed": not missing_packages,
        "missing_packages": missing_packages,
        "wpa_supplicant_active": False,
        "client_active": client_active,
    }

    try:
        result = run_cmd(["systemctl", "is-active", f"wpa_supplicant@{WLAN_IFACE}"], check=False)
        status["wpa_supplicant_active"] = result.returncode == 0
    except Exception:
        pass

    return status
