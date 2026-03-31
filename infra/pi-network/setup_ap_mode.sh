#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

WLAN_IFACE="${WLAN_IFACE:-wlan0}"
AP_SSID="${AP_SSID:-SmartCanePi}"
AP_PASSPHRASE="${AP_PASSPHRASE:-SmartCane1234}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_COUNTRY="${AP_COUNTRY:-US}"
AP_SUBNET_CIDR="${AP_SUBNET_CIDR:-192.168.4.1/24}"

echo "[1/7] Installing packages"
apt-get update
apt-get install -y hostapd dnsmasq

echo "[2/7] Stopping services before reconfigure"
systemctl stop hostapd || true
systemctl stop dnsmasq || true

echo "[3/7] Writing hostapd config"
cat >/etc/hostapd/hostapd.conf <<EOF
country_code=${AP_COUNTRY}
interface=${WLAN_IFACE}
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "[4/7] Writing dnsmasq config"
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
cat >/etc/dnsmasq.conf <<EOF
interface=${WLAN_IFACE}
bind-interfaces
dhcp-range=192.168.4.20,192.168.4.200,255.255.255.0,24h
domain-needed
bogus-priv
EOF

echo "[5/7] Writing dhcpcd static IP"
grep -q "# smartcane-ap" /etc/dhcpcd.conf || cat >>/etc/dhcpcd.conf <<EOF

# smartcane-ap
interface ${WLAN_IFACE}
  static ip_address=${AP_SUBNET_CIDR}
  nohook wpa_supplicant
EOF

echo "[6/7] Enabling AP services"
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq

echo "[7/7] Restarting networking services"
systemctl restart dhcpcd
systemctl restart hostapd
systemctl restart dnsmasq

mkdir -p /etc/smartcane
cat >/etc/smartcane/network_mode <<EOF
SMARTCANE_NETWORK_MODE=PI_AP
EOF

echo "AP mode configured. SSID=${AP_SSID}, interface=${WLAN_IFACE}"
