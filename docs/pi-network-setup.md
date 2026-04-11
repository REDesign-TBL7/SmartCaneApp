# Pi Network Provisioning Guide

This guide explains the direct Pi access-point networking flow.

## Modes

- `PI_ACCESS_POINT`: Pi always hosts its own Wi-Fi network for the iPhone app.

## Prerequisites

- Raspberry Pi OS with sudo access
- Repo checked out on Pi
- Wi-Fi adapter interface `wlan0` (default)

## 1) Install And Start AP Mode

1. Install the Pi services:

```bash
cd /path/to/your/repo
python3 -m venv pi/.venv
source pi/.venv/bin/activate
pip install -r pi/requirements.txt
deactivate

chmod +x infra/pi-network/smartcane_network.sh
sudo infra/pi-network/smartcane_network.sh install
```

2. The Pi boots into its own access point:

- SSID `SmartCane`
- passphrase `SmartCane123`
- Pi IP `192.168.4.1`
- app WebSocket endpoint `ws://192.168.4.1:8080/ws`

3. On iPhone, join the Pi Wi-Fi network manually in `Settings > Wi-Fi`.

4. Open the app and tap `Connect`.

Expected result:
- Pi advertises `SmartCane`
- iPhone joins `SmartCane`
- app connects directly to `192.168.4.1`

## 2) Check AP Status

```bash
cd /path/to/your/repo
chmod +x infra/pi-network/smartcane_network.sh
infra/pi-network/smartcane_network.sh status
```

The script reads `/etc/smartcane/network_mode` so you can verify AP mode quickly.

The installer derives the repo root from the script location, so the checkout does not need to live in `/opt/smart-cane`.

## Troubleshooting

- If setup AP does not appear: `sudo systemctl status smartcane-network-bootstrap hostapd dnsmasq`
- If app cannot connect: confirm the phone joined `SmartCane`
- If the Pi AP does not come up: check `journalctl -u smartcane-network-bootstrap -u hostapd -u dnsmasq -n 100`
- If app cannot connect: verify Pi runtime `sudo systemctl status smartcane-runtime`
- If app still cannot connect: check `pi/logs/pi_runtime.log` and confirm the phone can reach `192.168.4.1`
