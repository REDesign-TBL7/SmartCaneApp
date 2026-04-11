import logging
import os
import subprocess
import time
from pathlib import Path

logger = logging.getLogger(__name__)

AP_SSID = os.getenv("SMARTCANE_AP_SSID", "SmartCane")
AP_PASSPHRASE = os.getenv("SMARTCANE_AP_PASSPHRASE", "SmartCane123")
AP_IP = os.getenv("SMARTCANE_AP_IP", "192.168.4.1")
WLAN_IFACE = os.getenv("WLAN_IFACE", "wlan0")

HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"
DNSMASQ_CONF = "/etc/dnsmasq.conf"
DHCPCD_CONF = "/etc/dhcpcd.conf"
MODE_FILE = "/etc/smartcane/network_mode"


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
    packages = ["hostapd", "dnsmasq", "iw", "rfkill", "iproute2", "dhcpcd5"]
    missing = [p for p in packages if not check_package(p)]
    
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


def is_ap_active() -> bool:
    try:
        result = run_cmd(["systemctl", "is-active", "hostapd"], check=False)
        if result.returncode != 0:
            return False
        result = run_cmd(["systemctl", "is-active", "dnsmasq"], check=False)
        if result.returncode != 0:
            return False
        result = run_cmd(["ip", "addr", "show", WLAN_IFACE], check=False)
        return AP_IP in result.stdout
    except Exception:
        return False


def stop_services() -> None:
    for svc in ["wpa_supplicant", f"wpa_supplicant@{WLAN_IFACE}", "hostapd", "dnsmasq"]:
        run_cmd(["systemctl", "stop", svc], check=False)
        run_cmd(["systemctl", "disable", svc], check=False)


def reset_interface() -> None:
    run_cmd(["rfkill", "unblock", "wifi"], check=False)
    run_cmd(["ip", "link", "set", WLAN_IFACE, "down"], check=False)
    run_cmd(["ip", "addr", "flush", "dev", WLAN_IFACE], check=False)
    run_cmd(["ip", "link", "set", WLAN_IFACE, "up"], check=False)
    run_cmd(["iw", "dev", WLAN_IFACE, "set", "power_save", "off"], check=False)


def write_hostapd_conf() -> None:
    Path("/etc/hostapd").mkdir(exist_ok=True)
    conf = f"""country_code=SG
driver=nl80211
interface={WLAN_IFACE}
ssid={AP_SSID}
hw_mode=g
channel=1
ieee80211d=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase={AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
"""
    Path(HOSTAPD_CONF).write_text(conf)
    default_hostapd = Path("/etc/default/hostapd")
    if default_hostapd.exists():
        content = default_hostapd.read_text()
        if 'DAEMON_CONF=' not in content:
            content += f'\nDAEMON_CONF="{HOSTAPD_CONF}"\n'
        else:
            content = content.replace('DAEMON_CONF=', f'DAEMON_CONF="{HOSTAPD_CONF}"')
        default_hostapd.write_text(content)


def write_dnsmasq_conf() -> None:
    dhcp_start = AP_IP.rsplit(".", 1)[0] + ".20"
    dhcp_end = AP_IP.rsplit(".", 1)[0] + ".200"
    conf = f"""interface={WLAN_IFACE}
bind-interfaces
dhcp-range={dhcp_start},{dhcp_end},255.255.255.0,24h
domain-needed
bogus-priv
"""
    Path(DNSMASQ_CONF).write_text(conf)


def configure_dhcpcd() -> None:
    marker = "# smartcane-ap"
    content = Path(DHCPCD_CONF).read_text() if Path(DHCPCD_CONF).exists() else ""
    
    lines = content.splitlines()
    filtered = [l for l in lines if l != marker and not l.startswith(f"interface {WLAN_IFACE}")]
    
    filtered.append("")
    filtered.append(marker)
    filtered.append(f"interface {WLAN_IFACE}")
    filtered.append(f"static ip_address={AP_IP}/24")
    filtered.append("nohook wpa_supplicant")
    
    Path(DHCPCD_CONF).write_text("\n".join(filtered))


def write_mode_file() -> None:
    Path("/etc/smartcane").mkdir(exist_ok=True)
    Path(MODE_FILE).write_text(f"SMARTCANE_NETWORK_MODE=PI_ACCESS_POINT\nSMARTCANE_AP_SSID={AP_SSID}\nSMARTCANE_AP_IP={AP_IP}\n")


def start_ap_services() -> None:
    run_cmd(["systemctl", "unmask", "hostapd"], check=False)
    run_cmd(["systemctl", "enable", "dhcpcd"], check=False)
    run_cmd(["systemctl", "enable", "hostapd"], check=False)
    run_cmd(["systemctl", "enable", "dnsmasq"], check=False)
    
    run_cmd(["systemctl", "restart", "dhcpcd"], check=False)
    time.sleep(2)
    run_cmd(["systemctl", "restart", "hostapd"])
    run_cmd(["systemctl", "restart", "dnsmasq"])


def setup_ap(do_install: bool = False) -> bool:
    if not is_root():
        logger.error("AP setup requires root. Run: sudo python src/main.py --setup")
        return False
    
    logger.info("Setting up AP mode (SSID=%s, IP=%s)", AP_SSID, AP_IP)
    
    if do_install:
        install_packages()
    
    stop_services()
    reset_interface()
    
    write_hostapd_conf()
    write_dnsmasq_conf()
    configure_dhcpcd()
    write_mode_file()
    
    start_ap_services()
    
    for _ in range(10):
        if is_ap_active():
            logger.info("AP mode active: SSID=%s, IP=%s", AP_SSID, AP_IP)
            return True
        time.sleep(1)
    
    logger.error("AP setup failed")
    return False


def ensure_network(do_install: bool = False) -> bool:
    if is_ap_active():
        logger.info("Network already active")
        return True
    
    if not is_root():
        logger.warning("Network not active and no root - run with sudo for first-time setup")
        logger.info("Run: sudo python src/main.py --setup")
        return False
    
    logger.info("Network not active, setting up...")
    return setup_ap(do_install)


def get_status() -> dict:
    status = {
        "interface": WLAN_IFACE,
        "ap_ssid": AP_SSID,
        "ap_ip": AP_IP,
        "is_root": is_root(),
        "packages_installed": all(check_package(p) for p in ["hostapd", "dnsmasq"]),
        "hostapd_active": False,
        "dnsmasq_active": False,
        "ip_configured": False,
    }
    
    try:
        result = run_cmd(["systemctl", "is-active", "hostapd"], check=False)
        status["hostapd_active"] = result.returncode == 0
    except Exception:
        pass
    
    try:
        result = run_cmd(["systemctl", "is-active", "dnsmasq"], check=False)
        status["dnsmasq_active"] = result.returncode == 0
    except Exception:
        pass
    
    try:
        result = run_cmd(["ip", "addr", "show", WLAN_IFACE], check=False)
        status["ip_configured"] = AP_IP in result.stdout
    except Exception:
        pass
    
    return status
