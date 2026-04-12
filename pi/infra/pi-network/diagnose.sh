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

check_ap_ip() {
    if ip addr show "$WLAN" | grep -q "192.168.4.1"; then
        pass "$WLAN has AP IP 192.168.4.1"
    else
        fail "$WLAN missing AP IP"
        return 1
    fi
}

check_hostapd_conf() {
    if [[ -f /etc/hostapd/hostapd.conf ]]; then
        local ssid
        ssid=$(grep "^ssid=" /etc/hostapd/hostapd.conf 2>/dev/null | cut -d= -f2)
        pass "hostapd.conf exists (SSID: $ssid)"
    else
        fail "hostapd.conf missing"
        return 1
    fi
}

check_dnsmasq_conf() {
    if [[ -f /etc/dnsmasq.conf ]]; then
        if grep -q "dhcp-range=192.168.4" /etc/dnsmasq.conf 2>/dev/null; then
            pass "dnsmasq.conf has DHCP range"
        else
            warn "dnsmasq.conf missing DHCP range"
        fi
    else
        fail "dnsmasq.conf missing"
        return 1
    fi
}

check_python_venv() {
    local venv="${SCRIPT_DIR}/../../runtime/.venv"
    if [[ -d "$venv" ]]; then
        pass "Python venv exists"
        if "$venv/bin/python" -c "import websockets" 2>/dev/null; then
            pass "websockets module available"
        else
            fail "websockets module missing"
        fi
    else
        fail "Python venv missing"
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

check_rfkill() {
    local state
    state=$(rfkill list wifi 2>/dev/null | grep -o "Soft blocked: \(yes\|no\)" | head -1 | cut -d: -f2 | tr -d ' ')
    if [[ "$state" == "no" ]]; then
        pass "WiFi not soft-blocked"
    else
        fail "WiFi soft-blocked: rfkill unblock wifi"
        return 1
    fi
}

check_mode_file() {
    if [[ -f /etc/smartcane/network_mode ]]; then
        pass "Network mode file exists"
        info "Contents:"
        cat /etc/smartcane/network_mode | sed 's/^/  /'
    else
        warn "Network mode file missing"
    fi
}

quick_fix() {
    info "Attempting quick fixes..."
    
    rfkill unblock wifi 2>/dev/null || true
    
    if systemctl is-failed hostapd &>/dev/null; then
        warn "hostapd failed, restarting..."
        systemctl restart hostapd || true
    fi
    
    if systemctl is-failed dnsmasq &>/dev/null; then
        warn "dnsmasq failed, restarting..."
        systemctl restart dnsmasq || true
    fi
    
    if systemctl is-failed smartcane-runtime &>/dev/null; then
        warn "smartcane-runtime failed, restarting..."
        systemctl restart smartcane-runtime || true
    fi
}

print_summary() {
    echo
    echo "=========================================="
    echo "SmartCane Network Diagnostics"
    echo "=========================================="
}

print_summary

info "Checking packages..."
check_package hostapd
check_package dnsmasq
check_package iw

echo
info "Checking services..."
check_service hostapd
check_service dnsmasq
check_service dhcpcd
check_service smartcane-runtime
check_service_enabled smartcane-network-bootstrap
check_service_enabled smartcane-runtime

echo
info "Checking network..."
check_interface
check_ap_ip
check_rfkill

echo
info "Checking config files..."
check_hostapd_conf
check_dnsmasq_conf
check_mode_file

echo
info "Checking Python..."
check_python_venv

echo
info "Checking ports..."
check_port 8080
check_port 53
check_port 67

echo
info "Recent logs (last 5 lines):"
journalctl -u smartcane-runtime -u hostapd -u dnsmasq --no-pager -n 5 2>/dev/null | sed 's/^/  /'

echo
read -p "Run quick fixes? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    quick_fix
fi
