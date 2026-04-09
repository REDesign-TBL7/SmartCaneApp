#!/usr/bin/env bash
set -euo pipefail

WLAN_IFACE="${WLAN_IFACE:-wlan0}"
SETUP_AP_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/setup_ap_mode.sh"
HOTSPOT_CONF="/etc/wpa_supplicant/wpa_supplicant-${WLAN_IFACE}.conf"
MODE_FILE="/etc/smartcane/network_mode"

has_hotspot_config() {
  [[ -f "${HOTSPOT_CONF}" ]]
}

restart_client_mode() {
  systemctl disable hostapd || true
  systemctl disable dnsmasq || true
  systemctl stop hostapd || true
  systemctl stop dnsmasq || true
  systemctl enable dhcpcd
  systemctl enable "wpa_supplicant@${WLAN_IFACE}"
  systemctl restart dhcpcd
  systemctl restart "wpa_supplicant@${WLAN_IFACE}"
}

wait_for_wifi_association() {
  for _ in $(seq 1 20); do
    if iwgetid -r | grep -q .; then
      return 0
    fi
    sleep 1
  done
  return 1
}

mkdir -p /etc/smartcane

if has_hotspot_config; then
  restart_client_mode
  if wait_for_wifi_association; then
    cat >"${MODE_FILE}" <<EOF
SMARTCANE_NETWORK_MODE=PHONE_HOTSPOT_CLIENT
EOF
    exit 0
  fi
fi

"${SETUP_AP_SCRIPT}"
