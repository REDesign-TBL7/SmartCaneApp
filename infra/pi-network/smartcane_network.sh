#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
WLAN_IFACE="${WLAN_IFACE:-wlan0}"
MODE_FILE="/etc/smartcane/network_mode"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
DHCPCD_MARKER="# smartcane-ap"
AP_SSID="${SMARTCANE_AP_SSID:-SmartCane}"
AP_PASSPHRASE="${SMARTCANE_AP_PASSPHRASE:-SmartCane123}"
AP_CHANNEL="${SMARTCANE_AP_CHANNEL:-1}"
AP_COUNTRY="${SMARTCANE_AP_COUNTRY:-SG}"
AP_SUBNET_CIDR="${SMARTCANE_AP_SUBNET_CIDR:-192.168.4.1/24}"
RUNTIME_SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-runtime.service"
RUNTIME_SERVICE_DEST="/etc/systemd/system/smartcane-runtime.service"
BOOTSTRAP_SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-network-bootstrap.service"
BOOTSTRAP_SERVICE_DEST="/etc/systemd/system/smartcane-network-bootstrap.service"
SUDOERS_DEST="/etc/sudoers.d/smartcane-runtime"

usage() {
  cat <<EOF
Usage:
  sudo $0 install
  sudo $0 auto
  sudo $0 ap
  $0 status
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo $0 $*"
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  local package_hint="$2"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command '${command_name}'. Install package '${package_hint}' first."
    exit 1
  fi
}

require_runtime_tools() {
  require_command hostapd hostapd
  require_command dnsmasq dnsmasq
  require_command iw iw
  require_command rfkill rfkill
  require_command ip iproute2
  require_command systemctl systemd
}

record_mode() {
  mkdir -p /etc/smartcane
  cat >"${MODE_FILE}" <<EOF
SMARTCANE_NETWORK_MODE=PI_ACCESS_POINT
SMARTCANE_AP_SSID=${AP_SSID}
SMARTCANE_AP_IP=192.168.4.1
EOF
}

ensure_dhcpcd_conf() {
  if [[ ! -f "${DHCPCD_CONF}" ]]; then
    echo "Missing ${DHCPCD_CONF}. This script expects dhcpcd-managed networking."
    exit 1
  fi
}

replace_ap_dhcpcd_block() {
  ensure_dhcpcd_conf

  local tmp_file
  tmp_file=$(mktemp)
  awk -v marker="${DHCPCD_MARKER}" '
BEGIN { skip=0 }
$0 == marker { skip=1; next }
skip == 1 && /^$/ { skip=0; next }
skip == 0 { print }
' "${DHCPCD_CONF}" >"${tmp_file}"

  cat >>"${tmp_file}" <<EOF

${DHCPCD_MARKER}
interface ${WLAN_IFACE}
  static ip_address=${AP_SUBNET_CIDR}
  nohook wpa_supplicant
EOF

  cp "${tmp_file}" "${DHCPCD_CONF}"
  rm -f "${tmp_file}"
}

reset_wifi_interface() {
  rfkill unblock wifi || true
  ip link set "${WLAN_IFACE}" down || true
  ip addr flush dev "${WLAN_IFACE}" || true
  ip link set "${WLAN_IFACE}" up || true
  iw reg set "${AP_COUNTRY}" || true
  iw dev "${WLAN_IFACE}" set power_save off || true
}

apply_ap_mode() {
  require_runtime_tools

  echo "[1/5] Stopping client-mode services"
  systemctl disable "wpa_supplicant@${WLAN_IFACE}" >/dev/null 2>&1 || true
  systemctl stop "wpa_supplicant@${WLAN_IFACE}" >/dev/null 2>&1 || true
  systemctl stop wpa_supplicant.service >/dev/null 2>&1 || true
  systemctl stop NetworkManager >/dev/null 2>&1 || true
  systemctl stop hostapd >/dev/null 2>&1 || true
  systemctl stop dnsmasq >/dev/null 2>&1 || true

  echo "[2/5] Resetting ${WLAN_IFACE}"
  reset_wifi_interface

  echo "[3/5] Writing AP configuration"
  cat >"${HOSTAPD_CONF}" <<EOF
country_code=${AP_COUNTRY}
driver=nl80211
interface=${WLAN_IFACE}
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
ieee80211d=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
  sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

  cat >"${DNSMASQ_CONF}" <<EOF
interface=${WLAN_IFACE}
bind-interfaces
dhcp-range=192.168.4.20,192.168.4.200,255.255.255.0,24h
domain-needed
bogus-priv
EOF

  replace_ap_dhcpcd_block

  echo "[4/5] Starting AP services"
  systemctl enable dhcpcd >/dev/null 2>&1 || true
  systemctl restart dhcpcd
  systemctl unmask hostapd
  systemctl enable hostapd >/dev/null 2>&1
  systemctl enable dnsmasq >/dev/null 2>&1
  systemctl restart hostapd
  systemctl restart dnsmasq

  echo "[5/5] Recording SmartCane AP mode"
  record_mode
  echo "SmartCane AP active: SSID=${AP_SSID}, IP=192.168.4.1"
}

auto_mode() {
  apply_ap_mode
}

print_status() {
  echo "=== SmartCane Pi network status ==="
  echo
  echo "Interface: ${WLAN_IFACE}"
  ip addr show "${WLAN_IFACE}" || true
  echo
  echo "Active SSID:"
  iw dev 2>/dev/null || true
  echo
  echo "Service status:"
  systemctl is-enabled hostapd 2>/dev/null || true
  systemctl is-active hostapd 2>/dev/null || true
  systemctl is-enabled dnsmasq 2>/dev/null || true
  systemctl is-active dnsmasq 2>/dev/null || true
  systemctl is-enabled dhcpcd 2>/dev/null || true
  systemctl is-active dhcpcd 2>/dev/null || true
  echo
  echo "rfkill:"
  rfkill list 2>/dev/null || true
  echo
  echo "SmartCane mode file:"
  if [[ -f "${MODE_FILE}" ]]; then
    cat "${MODE_FILE}"
  else
    echo "(not set)"
  fi
}

install_services() {
  require_root install
  echo "[1/7] Installing Pi network packages"
  apt-get update
  apt-get install -y hostapd dnsmasq iw rfkill iproute2 dhcpcd5

  echo "[2/7] Installing systemd units for repo root ${REPO_ROOT}"
  sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" "${RUNTIME_SERVICE_SRC}" >"${RUNTIME_SERVICE_DEST}"
  sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" "${BOOTSTRAP_SERVICE_SRC}" >"${BOOTSTRAP_SERVICE_DEST}"

  echo "[3/7] Ensuring network script is executable"
  chmod +x "${SCRIPT_DIR}/smartcane_network.sh"

  echo "[4/7] Installing sudoers rule for the Pi runtime"
  cat >"${SUDOERS_DEST}" <<EOF
pi ALL=(root) NOPASSWD: ${SCRIPT_DIR}/smartcane_network.sh
EOF
  chmod 440 "${SUDOERS_DEST}"

  echo "[5/7] Reloading systemd"
  systemctl daemon-reload

  echo "[6/7] Enabling and restarting SmartCane services"
  systemctl enable smartcane-network-bootstrap.service
  systemctl restart smartcane-network-bootstrap.service
  systemctl enable smartcane-runtime.service
  systemctl restart smartcane-runtime.service

  echo "[7/7] Install complete"
}

COMMAND="${1:-}"
if [[ -z "${COMMAND}" ]]; then
  usage
  exit 1
fi
shift || true

case "${COMMAND}" in
  install)
    install_services
    ;;
  auto)
    require_root auto
    auto_mode
    ;;
  ap)
    require_root ap
    apply_ap_mode
    ;;
  status)
    print_status
    ;;
  *)
    usage
    exit 1
    ;;
esac
