import logging
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from diagnostics_state import diagnostics_state

logger = logging.getLogger(__name__)

WLAN_IFACE = os.getenv("WLAN_IFACE", "wlan0")
MODE_FILE = "/etc/smartcane/network_mode"
HOTSPOT_CONFIG_PATH = Path("/etc/smartcane/hotspot.json")
BOOT_CONFIG_CANDIDATES = [
    Path("/boot/firmware/smartcane-hotspot.json"),
    Path("/boot/smartcane-hotspot.json"),
]
PACKAGE_NAMES = ["iw", "rfkill", "iproute2", "network-manager", "bluez"]
_NM_CONN_PREFIX = "smartcane-wifi-"


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
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if check and result.returncode != 0:
        logger.error("Command failed %s: %s", cmd, result.stderr.strip())
        raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
    if result.returncode != 0:
        logger.debug("Command %s exited %d: %s", cmd, result.returncode, result.stderr.strip())
    return result


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
    if shutil.which("iwgetid") is not None:
        try:
            result = run_cmd(["iwgetid", "-r"], check=False)
            ssid = result.stdout.strip()
            if result.returncode == 0 and ssid:
                return ssid
        except Exception:
            pass

    try:
        result = run_cmd(
            ["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"],
            check=False,
        )
        for line in result.stdout.splitlines():
            active, _, ssid = line.partition(":")
            if active == "yes":
                return ssid
    except Exception:
        pass

    if shutil.which("iw") is not None:
        try:
            result = run_cmd(["iw", "dev", WLAN_IFACE, "link"], check=False)
            for line in result.stdout.splitlines():
                line = line.strip()
                if line.startswith("SSID: "):
                    return line.split("SSID: ", 1)[1].strip()
        except Exception:
            pass

    return ""


def stop_services() -> None:
    for svc in ["hostapd", "dnsmasq"]:
        run_cmd(["systemctl", "stop", svc], check=False)
        run_cmd(["systemctl", "disable", svc], check=False)


def reset_interface() -> None:
    run_cmd(["rfkill", "unblock", "wifi"], check=False)
    run_cmd(["nmcli", "radio", "wifi", "on"], check=False)
    run_cmd(["iw", "dev", WLAN_IFACE, "set", "power_save", "off"], check=False)


def configure_nm_connections(networks: list[dict[str, str]]) -> None:
    # Remove previously managed connections so stale credentials don't linger.
    result = run_cmd(["nmcli", "-t", "-f", "NAME", "connection", "show"], check=False)
    for name in result.stdout.splitlines():
        name = name.strip()
        if name.startswith(_NM_CONN_PREFIX):
            run_cmd(["nmcli", "connection", "delete", name], check=False)

    for i, network in enumerate(networks):
        result = run_cmd([
            "nmcli", "connection", "add",
            "type", "wifi",
            "ifname", WLAN_IFACE,
            "con-name", f"{_NM_CONN_PREFIX}{i}",
            "ssid", network["ssid"],
            "wifi-sec.key-mgmt", "wpa-psk",
            "wifi-sec.psk", network["password"],
            "connection.autoconnect", "yes",
            "connection.autoconnect-priority", str(100 - i),
            # 0 = unlimited retries so NM never permanently gives up on this profile.
            "connection.autoconnect-retries", "0",
        ], check=False)
        if result.returncode == 0:
            logger.info("Created NM connection %s%d for SSID %s", _NM_CONN_PREFIX, i, network["ssid"])
        else:
            logger.error("Failed to create NM connection for SSID %s: %s", network["ssid"], result.stderr.strip())


def start_hotspot_client() -> None:
    _log_diagnostic("Activating Wi-Fi via NetworkManager")
    run_cmd(["systemctl", "start", "NetworkManager"], check=False)
    run_cmd(["nmcli", "radio", "wifi", "on"], check=False)
    # Kick off a scan so NM finds the SSID sooner — but do NOT call
    # `nmcli connection up` here. Forcing activation before the scan
    # completes causes NM to record a failed attempt; after a few failures
    # NM stops autoconnecting the profile entirely. Let NM's own autoconnect
    # logic handle the connection once the scan result is ready.
    run_cmd(["nmcli", "device", "wifi", "rescan"], check=False)


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

    if get_connected_ssid():
        return True

    try:
        result = run_cmd(
            ["nmcli", "-t", "-f", "DEVICE,STATE", "device", "status"],
            check=False,
        )
        for line in result.stdout.splitlines():
            device, _, state = line.partition(":")
            if device == WLAN_IFACE and state == "connected":
                return True
    except Exception:
        pass
    return False


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

    configure_nm_connections(networks)
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

    for _ in range(60):
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
    failure_reason = "associated but no DHCP lease" if connected_ssid else "no configured network in range or wrong credentials"
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


def _nm_connections_configured() -> bool:
    result = run_cmd(["nmcli", "-t", "-f", "NAME", "connection", "show"], check=False)
    return any(
        name.strip().startswith(_NM_CONN_PREFIX)
        for name in result.stdout.splitlines()
    )


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

    # Only configure NM once. If profiles already exist NM is handling autoconnect —
    # deleting and re-adding them every few seconds would cancel any in-progress attempt.
    if _nm_connections_configured():
        diagnostics_state.add_message("Waiting for existing NetworkManager Wi-Fi profiles to connect")
        return False

    logger.info("No NM connections configured yet, running initial hotspot setup...")
    return setup_hotspot_client(do_install)


def write_mode_file(mode: str, extra: dict[str, str] | None = None) -> None:
    Path("/etc/smartcane").mkdir(exist_ok=True)
    lines = [f"SMARTCANE_NETWORK_MODE={mode}"]
    for key, value in (extra or {}).items():
        lines.append(f"{key}={value}")
    Path(MODE_FILE).write_text("\n".join(lines) + "\n")


def get_status() -> dict:
    ip_address = get_ipv4_address(WLAN_IFACE)
    client_active = is_hotspot_client_active()
    credentials = load_hotspot_credentials()
    networks = list(credentials["networks"]) if credentials else []
    missing_packages = [package for package in PACKAGE_NAMES if not check_package(package)]
    connected_ssid = get_connected_ssid()
    status = {
        "interface": WLAN_IFACE,
        "mode": "PHONE_HOTSPOT_CLIENT" if (client_active or (ip_address and connected_ssid)) else "UNCONFIGURED",
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
        "nm_active": False,
        "client_active": client_active,
    }

    try:
        result = run_cmd(["nmcli", "-t", "-f", "DEVICE,STATE", "device", "status"], check=False)
        for line in result.stdout.splitlines():
            device, _, state = line.partition(":")
            if device == WLAN_IFACE:
                status["nm_active"] = state == "connected"
                break
    except Exception:
        pass

    return status
