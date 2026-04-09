# Pi Network Provisioning Guide

This guide explains exactly how to switch the Pi between the two supported outdoor modes.

## Modes

- `PI_AP`: Pi hosts its own access point (`SmartCanePi`) and phone joins it.
- `PHONE_HOTSPOT_CLIENT`: Pi joins the iPhone hotspot; phone keeps cellular internet.

## Prerequisites

- Raspberry Pi OS with sudo access
- Repo checked out on Pi (recommended path: `/opt/smart-cane`)
- Wi-Fi adapter interface `wlan0` (default)

## 1) Configure Pi AP mode

```bash
cd /opt/smart-cane
chmod +x infra/pi-network/setup_ap_mode.sh
sudo AP_SSID="SmartCanePi" AP_PASSPHRASE="ChangeMe123" infra/pi-network/setup_ap_mode.sh
```

Shortcut:

```bash
infra/pi-network/use_mode.sh ap
```

Expected result:
- Pi advertises SSID `SmartCanePi`
- Pi IP is `192.168.4.1`
- iOS app `Pi AP` profile should connect to `ws://192.168.4.1:8080/ws`

## 2) Configure phone hotspot client mode

```bash
cd /opt/smart-cane
chmod +x infra/pi-network/setup_hotspot_client_mode.sh
sudo infra/pi-network/setup_hotspot_client_mode.sh --ssid "<iPhone hotspot name>" --psk "<hotspot password>"
```

Shortcut:

```bash
infra/pi-network/use_mode.sh hotspot --ssid "<iPhone hotspot name>" --psk "<hotspot password>"
```

Expected result:
- Pi joins phone hotspot
- Pi gets DHCP address (often `172.20.10.2`)
- iOS app `Hotspot` profile should connect to `ws://172.20.10.2:8080/ws`

## 3) Check active mode

```bash
cd /opt/smart-cane
chmod +x infra/pi-network/check_network_mode.sh
infra/pi-network/check_network_mode.sh
```

The script reads `/etc/smartcane/network_mode` so you can verify selected mode quickly.

## 4) Install runtime service

```bash
cd /opt/smart-cane
python3 -m venv pi/.venv
source pi/.venv/bin/activate
pip install -r pi/requirements.txt
deactivate

chmod +x infra/pi-network/install_runtime_service.sh
sudo infra/pi-network/install_runtime_service.sh
```

This installs and starts `smartcane-runtime.service`.

## Troubleshooting

- If AP does not appear: `sudo systemctl status hostapd dnsmasq`
- If hotspot join fails: verify SSID/password and run `journalctl -u wpa_supplicant@wlan0 -n 100`
- If app cannot connect: verify Pi runtime `sudo systemctl status smartcane-runtime`
