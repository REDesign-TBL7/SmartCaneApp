#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
WLAN="${WLAN_IFACE:-wlan0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo "[INFO] $*"; }

check_package() {
    local pkg="$1"
    if dpkg -l "$pkg" &>/dev/null; then
        pass "$pkg installed"
    else
        fail "$pkg NOT installed"
        return 1
    fi
}

check_service() {
    local svc="$1"
    local state
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    if [[ "$state" == "active" ]]; then
        pass "$svc running"
    else
        fail "$svc NOT running (state: $state)"
        return 1
    fi
}

check_service_enabled() {
    local svc="$1"
    if systemctl is-enabled "$svc" &>/dev/null; then
        pass "$svc enabled"
    else
        warn "$svc not enabled"
    fi
}

check_interface() {
    if ip link show "$WLAN" &>/dev/null; then
        local state
        state=$(ip -o link show "$WLAN" | awk '{print $9}')
        pass "$WLAN exists (state: $state)"
    else
        fail "$WLAN interface not found"
        return 1
    fi
}

check_nm_wifi_connected() {
    local device_state
    device_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | grep "^${WLAN}:" | cut -d: -f2 || echo "unknown")
    if [[ "$device_state" == "connected" ]]; then
        local ssid
        ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null \
            | grep '^yes:' | cut -d: -f2 || echo "")
        pass "NetworkManager: $WLAN connected (SSID: ${ssid:-unknown})"
    else
        fail "NetworkManager: $WLAN not connected (state: $device_state)"
        return 1
    fi
}

check_ip_address() {
    local ip
    ip=$(ip -4 addr show "$WLAN" 2>/dev/null \
        | awk '/inet / {split($2,a,"/"); print a[1]}' | head -1)
    if [[ -n "$ip" ]]; then
        pass "$WLAN has IP $ip"
    else
        fail "$WLAN has no IPv4 address"
        return 1
    fi
}

check_hotspot_config() {
    local found=0
    for path in /etc/smartcane/hotspot.json /boot/firmware/smartcane-hotspot.json /boot/smartcane-hotspot.json; do
        if [[ -f "$path" ]]; then
            local ssid
            ssid=$(python3 -c "import json,sys; d=json.load(open('$path')); \
                nets=d.get('networks'); \
                print(nets[0]['ssid'] if nets else d.get('hotspotSSID','?'))" 2>/dev/null || echo "?")
            pass "Hotspot config found at $path (primary SSID: $ssid)"
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        warn "No hotspot config found — provision via BLE or place smartcane-hotspot.json on boot partition"
    fi
}

check_nm_connections() {
    local conns
    conns=$(nmcli -t -f NAME connection show 2>/dev/null | grep '^smartcane-wifi-' | tr '\n' ' ')
    if [[ -n "$conns" ]]; then
        pass "NM smartcane connections: $conns"
    else
        warn "No smartcane-wifi-* NM connections found — hotspot not yet provisioned"
    fi
}

check_python_runtime() {
    local repo_root
    repo_root=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
    local venv="${repo_root}/runtime/.venv"
    local vendor="${repo_root}/runtime/vendor"
    if [[ -d "$venv" ]]; then
        pass "Python venv exists"
        if "$venv/bin/python" -c "import websockets" 2>/dev/null; then
            pass "websockets importable from venv"
        else
            fail "websockets missing from venv"
        fi
    elif [[ -d "$vendor" ]]; then
        pass "Python vendor dir exists (OTA mode)"
        if PYTHONPATH="$vendor" python3 -c "import websockets" 2>/dev/null; then
            pass "websockets importable from vendor"
        else
            fail "websockets missing from vendor"
        fi
    else
        fail "Neither venv nor vendor dir found"
    fi
}

check_rfkill() {
    local state
    state=$(rfkill list wifi 2>/dev/null \
        | grep -o "Soft blocked: \(yes\|no\)" | head -1 | cut -d: -f2 | tr -d ' ')
    if [[ "$state" == "no" ]]; then
        pass "WiFi not soft-blocked"
    else
        fail "WiFi soft-blocked — run: rfkill unblock wifi"
        return 1
    fi
}

check_mode_file() {
    if [[ -f /etc/smartcane/network_mode ]]; then
        pass "Network mode file exists"
        info "Contents:"
        sed 's/^/  /' /etc/smartcane/network_mode
    else
        warn "Network mode file missing (not yet provisioned)"
    fi
}

check_port() {
    local port="$1"
    if ss -tuln | grep -q ":${port} "; then
        pass "Port $port listening"
    else
        warn "Port $port not listening"
    fi
}

quick_fix() {
    info "Attempting quick fixes..."

    rfkill unblock wifi 2>/dev/null || true

    if ! systemctl is-active --quiet NetworkManager; then
        warn "NetworkManager not running, starting..."
        systemctl start NetworkManager || true
    fi

    if ! systemctl is-active --quiet avahi-daemon; then
        warn "avahi-daemon not running, starting..."
        systemctl start avahi-daemon || true
    fi

    if systemctl is-failed smartcane-runtime &>/dev/null; then
        warn "smartcane-runtime failed, restarting..."
        systemctl restart smartcane-runtime || true
    fi
}

echo "=========================================="
echo "SmartCane Network Diagnostics"
echo "=========================================="
echo

info "Checking packages..."
check_package network-manager
check_package avahi-daemon
check_package iw
echo

info "Checking services..."
check_service NetworkManager
check_service avahi-daemon
check_service smartcane-runtime
check_service_enabled smartcane-runtime
echo

info "Checking Wi-Fi..."
check_interface
check_rfkill
check_nm_wifi_connected
check_ip_address
echo

info "Checking hotspot configuration..."
check_hotspot_config
check_nm_connections
check_mode_file
echo

info "Checking Python runtime..."
check_python_runtime
echo

info "Checking ports..."
check_port 8080
echo

info "Recent logs (last 10 lines):"
journalctl -u smartcane-runtime -u NetworkManager --no-pager -n 10 2>/dev/null | sed 's/^/  /'

echo
read -p "Run quick fixes? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    quick_fix
fi
