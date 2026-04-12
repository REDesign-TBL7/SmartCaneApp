#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
WLAN="${WLAN_IFACE:-wlan0}"

log() { echo "[Reset] $*"; }

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

log "Stopping all services..."
systemctl stop smartcane-runtime 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop wpa_supplicant 2>/dev/null || true
systemctl stop wpa_supplicant@${WLAN} 2>/dev/null || true

log "Resetting interface ${WLAN}..."
rfkill unblock wifi || true
ip link set ${WLAN} down || true
ip addr flush dev ${WLAN} || true
ip link set ${WLAN} up || true

log "Clearing old configs..."
rm -f /etc/hostapd/hostapd.conf
rm -f /etc/dnsmasq.conf

log "Reapplying AP configuration..."
"${SCRIPT_DIR}/smartcane_network.sh" auto

log "Starting services..."
systemctl restart smartcane-runtime

log "Reset complete. Status:"
"${SCRIPT_DIR}/smartcane_network.sh" status
