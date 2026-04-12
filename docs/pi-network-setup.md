# Pi Network Provisioning Guide

## Quick Start (Recommended)

From the Pi, one command sets up everything:

```bash
cd /path/to/SmartCaneApp/pi
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
sudo .venv/bin/python src/main.py
```

That's it. The Pi will:
1. Auto-configure AP mode (SSID: `SmartCane`, Password: `SmartCane123`)
2. Start WebSocket server on `ws://192.168.4.1:8080/ws`

On iPhone: Join `SmartCane` WiFi, then open the app and tap Connect.

## Commands

```bash
# Start runtime (auto-setup network if needed)
sudo python src/main.py

# Setup network only, don't start runtime
sudo python src/main.py --setup

# Enter temporary AP test mode safely from an SSH session on client Wi-Fi
sudo python src/main.py --ap-test 300

# Check network status
python src/main.py --status

# Enter temporary AP test mode and auto-rollback after 5 minutes unless the app confirms success
sudo infra/pi-network/smartcane_network.sh ap-test --rollback 300

# Inspect current AP / rollback state
infra/pi-network/smartcane_network.sh status

# Help
python src/main.py --help
```

## Systemd Service (Auto-start on boot)

```bash
cd /path/to/SmartCaneApp

# Create venv and install deps
python3 -m venv pi/.venv
source pi/.venv/bin/activate
pip install -r pi/requirements.txt
deactivate

# Install service
sudo sed "s|__SMARTCANE_REPO_ROOT__|$(pwd)|g" \
    infra/pi-network/systemd/smartcane-runtime.service \
    > /etc/systemd/system/smartcane-runtime.service

sudo systemctl daemon-reload
sudo systemctl enable smartcane-runtime
sudo systemctl start smartcane-runtime

# Check status
sudo systemctl status smartcane-runtime
journalctl -u smartcane-runtime -f
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SMARTCANE_AP_SSID` | `SmartCane` | WiFi network name |
| `SMARTCANE_AP_PASSPHRASE` | `SmartCane123` | WiFi password |
| `SMARTCANE_AP_IP` | `192.168.4.1` | Pi IP address |
| `WLAN_IFACE` | `wlan0` | WiFi interface |
| `SMARTCANE_LOG_LEVEL` | `INFO` | Log level (DEBUG, INFO, WARNING) |

## How It Works

1. `main.py` starts and calls `ensure_network()`
2. If AP is already active → continues to runtime
3. If not root → prints error and exits
4. If root → configures AP mode automatically

The network setup:
- Installs packages (hostapd, dnsmasq, etc.)
- Configures hostapd for AP mode
- Configures dnsmasq for DHCP
- Configures dhcpcd for static IP
- Starts all services

## Headless AP Testing

Use this when you are SSHed into the Pi over an existing client Wi-Fi network and
need to test the phone app against the Pi AP without permanently stranding the Pi.

1. SSH into the Pi on the existing client network.
2. Run:

```bash
sudo python src/main.py --ap-test 300
```

3. The Pi switches to the `SmartCane` AP and arms a 5-minute rollback timer.
4. Your SSH session drops. This is expected.
5. Join `SmartCane` on the iPhone and test the app connection.
6. If the app connects successfully, it sends `AP_TEST_CONFIRM` and the Pi keeps AP mode.
7. If the app never confirms success, the Pi automatically restores the previous
   client Wi-Fi config and SSH becomes reachable again after the rollback fires.

## Troubleshooting

### Check status
```bash
python src/main.py --status
```

### Manual network reset
```bash
sudo systemctl restart hostapd dnsmasq dhcpcd
```

### Full network setup
```bash
sudo python src/main.py --setup
```

### View logs
```bash
journalctl -u smartcane-runtime -f
# Or if running manually:
tail -f pi/logs/pi_runtime.log
```

### AP not appearing
1. Check WiFi interface: `ip link show`
2. Check rfkill: `rfkill list`
3. Unblock WiFi: `sudo rfkill unblock wifi`
4. Re-run setup: `sudo python src/main.py --setup`

### App cannot connect
1. Confirm phone joined `SmartCane` WiFi
2. Check Pi IP: `ip addr show wlan0 | grep 192.168.4`
3. Test port: `nc -zv 192.168.4.1 8080`
