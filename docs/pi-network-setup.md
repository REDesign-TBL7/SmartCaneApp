# Pi Network Provisioning Guide

This guide explains the supported onboarding and run-time networking flow.

## Modes

- `PI_SETUP_AP`: Pi hosts `SmartCaneSetup` for first-time onboarding.
- `PHONE_HOTSPOT_CLIENT`: Pi joins the iPhone hotspot for normal use.

## Prerequisites

- Raspberry Pi OS with sudo access
- Repo checked out on Pi (recommended path: `/opt/smart-cane`)
- Wi-Fi adapter interface `wlan0` (default)

## 1) First-time onboarding

1. Install the Pi services:

```bash
cd /opt/smart-cane
python3 -m venv pi/.venv
source pi/.venv/bin/activate
pip install -r pi/requirements.txt
deactivate

chmod +x infra/pi-network/install_runtime_service.sh
sudo infra/pi-network/install_runtime_service.sh
```

2. If no hotspot config exists, the Pi will automatically boot into:

- SSID `SmartCaneSetup`
- passphrase `SmartCaneSetup123`
- setup server `http://192.168.4.1:8081`

3. Open the iPhone app and use `Set up cane`.

4. In iPhone `Settings > Wi-Fi`, manually join:

- SSID `SmartCaneSetup`
- passphrase `SmartCaneSetup123`

5. Return to the app. The app sends hotspot credentials to the setup server, and the Pi switches to hotspot mode.

## 2) Configure phone hotspot client mode manually

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
- Pi gets a DHCP address from the iPhone hotspot
- Pi advertises `_smartcane._tcp` over Bonjour / mDNS
- iOS app discovers the Pi by service name and device ID, then connects to the resolved WebSocket endpoint

Fallback:

- If Bonjour is temporarily unavailable, the app still tries `ws://172.20.10.2:8080/ws`

## 3) Check active mode

```bash
cd /opt/smart-cane
chmod +x infra/pi-network/check_network_mode.sh
infra/pi-network/check_network_mode.sh
```

The script reads `/etc/smartcane/network_mode` so you can verify hotspot mode quickly.

## Troubleshooting

- If setup AP does not appear: `sudo systemctl status smartcane-network-bootstrap hostapd dnsmasq`
- If app setup fails: confirm the phone joined `SmartCaneSetup`
- If the Pi never leaves setup mode: check `pi/logs/pi_runtime.log` for setup-server errors
- If hotspot join fails: verify SSID/password and run `journalctl -u wpa_supplicant@wlan0 -n 100`
- If app cannot connect: verify Pi runtime `sudo systemctl status smartcane-runtime`
- If app cannot discover Pi: check `pi/logs/pi_runtime.log` for `Published mDNS service` and make sure `zeroconf` is installed in the Pi venv
