#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0 --ssid <name> --psk <password>"
  exit 1
fi

WLAN_IFACE="${WLAN_IFACE:-wlan0}"
SSID=""
PSK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssid)
      SSID="$2"
      shift 2
      ;;
    --psk)
      PSK="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${SSID}" || -z "${PSK}" ]]; then
  echo "Usage: sudo $0 --ssid <name> --psk <password>"
  exit 1
fi

echo "[0/6] Preparing hotspot client mode for SSID=${SSID}"
echo "[1/6] Disabling AP services"
systemctl disable hostapd || true
systemctl disable dnsmasq || true
systemctl stop hostapd || true
systemctl stop dnsmasq || true

echo "[2/6] Restoring dnsmasq default if backup exists"
if [[ -f /etc/dnsmasq.conf.orig ]]; then
  cp /etc/dnsmasq.conf.orig /etc/dnsmasq.conf
fi

echo "[3/6] Removing smartcane-ap block from dhcpcd"
tmp_file=$(mktemp)
awk '
BEGIN { skip=0 }
/^# smartcane-ap$/ { skip=1; next }
skip==1 && /^$/ { skip=0; next }
skip==0 { print }
' /etc/dhcpcd.conf >"${tmp_file}"
cp "${tmp_file}" /etc/dhcpcd.conf
rm -f "${tmp_file}"

echo "[4/6] Configuring wpa_supplicant for phone hotspot"
wpa_passphrase "${SSID}" "${PSK}" >/etc/wpa_supplicant/wpa_supplicant-${WLAN_IFACE}.conf
chmod 600 /etc/wpa_supplicant/wpa_supplicant-${WLAN_IFACE}.conf

echo "[5/6] Ensuring dhcpcd and wpa_supplicant are enabled"
systemctl enable dhcpcd
systemctl enable wpa_supplicant@${WLAN_IFACE}

echo "[6/6] Restarting network services"
systemctl restart dhcpcd
systemctl restart wpa_supplicant@${WLAN_IFACE}

echo "[7/7] Recording SmartCane network mode"
mkdir -p /etc/smartcane
cat >/etc/smartcane/network_mode <<EOF
SMARTCANE_NETWORK_MODE=PHONE_HOTSPOT_CLIENT
SMARTCANE_HOTSPOT_SSID=${SSID}
EOF

echo "Hotspot client mode configured for SSID=${SSID}"
