#!/usr/bin/env bash
set -euo pipefail

WLAN_IFACE="${WLAN_IFACE:-wlan0}"

echo "=== SmartCane Pi network status ==="
echo

echo "Interface: ${WLAN_IFACE}"
ip addr show "${WLAN_IFACE}" || true
echo

echo "Active SSID (if client mode):"
iwgetid -r || true
echo

echo "Service status:"
systemctl is-enabled hostapd 2>/dev/null || true
systemctl is-active hostapd 2>/dev/null || true
systemctl is-enabled dnsmasq 2>/dev/null || true
systemctl is-active dnsmasq 2>/dev/null || true
systemctl is-enabled wpa_supplicant.service 2>/dev/null || true
systemctl is-active wpa_supplicant.service 2>/dev/null || true
systemctl is-enabled "wpa_supplicant@${WLAN_IFACE}" 2>/dev/null || true
systemctl is-active "wpa_supplicant@${WLAN_IFACE}" 2>/dev/null || true
systemctl is-enabled NetworkManager 2>/dev/null || true
systemctl is-active NetworkManager 2>/dev/null || true

echo
echo "rfkill:"
rfkill list 2>/dev/null || true

echo
echo "iw dev:"
iw dev 2>/dev/null || true

echo
echo "SmartCane mode file:"
if [[ -f /etc/smartcane/network_mode ]]; then
  cat /etc/smartcane/network_mode
else
  echo "(not set)"
fi
echo

echo "Inference:"
if systemctl is-active --quiet hostapd; then
  echo "Mode looks like: PI_SETUP_AP"
elif systemctl is-active --quiet "wpa_supplicant@${WLAN_IFACE}"; then
  echo "Mode looks like: PHONE_HOTSPOT_CLIENT"
else
  echo "Mode not active on ${WLAN_IFACE}"
fi
