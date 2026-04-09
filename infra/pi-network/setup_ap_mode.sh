#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

WLAN_IFACE="${WLAN_IFACE:-wlan0}"
AP_SSID="${AP_SSID:-SmartCaneSetup}"
AP_PASSPHRASE="${AP_PASSPHRASE:-SmartCaneSetup123}"
AP_CHANNEL="${AP_CHANNEL:-1}"
AP_COUNTRY="${AP_COUNTRY:-SG}"
AP_SUBNET_CIDR="${AP_SUBNET_CIDR:-192.168.4.1/24}"

apt-get update
apt-get install -y hostapd dnsmasq iw rfkill

rfkill unblock wifi || true
systemctl disable wpa_supplicant.service || true
systemctl stop wpa_supplicant.service || true
systemctl disable "wpa_supplicant@${WLAN_IFACE}" || true
systemctl stop "wpa_supplicant@${WLAN_IFACE}" || true
systemctl stop NetworkManager || true
systemctl stop hostapd || true
systemctl stop dnsmasq || true

ip link set "${WLAN_IFACE}" down || true
ip addr flush dev "${WLAN_IFACE}" || true
ip link set "${WLAN_IFACE}" up || true
iw reg set "${AP_COUNTRY}" || true
iw dev "${WLAN_IFACE}" set power_save off || true

cat >/etc/hostapd/hostapd.conf <<EOF
country_code=${AP_COUNTRY}
driver=nl80211
interface=${WLAN_IFACE}
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
ieee80211d=1
wmm_enabled=1
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

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
cat >/etc/dnsmasq.conf <<EOF
interface=${WLAN_IFACE}
bind-interfaces
dhcp-range=192.168.4.20,192.168.4.200,255.255.255.0,24h
domain-needed
bogus-priv
EOF

grep -q "# smartcane-ap" /etc/dhcpcd.conf || cat >>/etc/dhcpcd.conf <<EOF

# smartcane-ap
interface ${WLAN_IFACE}
  static ip_address=${AP_SUBNET_CIDR}
  nohook wpa_supplicant
EOF

systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl restart dhcpcd
systemctl restart hostapd
systemctl restart dnsmasq

mkdir -p /etc/smartcane
cat >/etc/smartcane/network_mode <<EOF
SMARTCANE_NETWORK_MODE=PI_SETUP_AP
SMARTCANE_SETUP_SSID=${AP_SSID}
EOF

echo "Setup AP mode configured. SSID=${AP_SSID}, interface=${WLAN_IFACE}"
echo "hostapd status:"
systemctl --no-pager --full status hostapd || true
echo "interface status:"
iw dev || true
