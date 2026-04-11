#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
PI_DIR="${REPO_ROOT}/pi"

log() { echo "[SmartCane] $*"; }
fail() { echo "[SmartCane ERROR] $*" >&2; exit 1; }

install_packages() {
    log "Installing required packages..."
    apt-get update -qq
    apt-get install -y -qq hostapd dnsmasq iw rfkill iproute2 dhcpcd5 python3-venv
}

setup_python_venv() {
    log "Setting up Python virtual environment..."
    if [[ ! -d "${PI_DIR}/.venv" ]]; then
        python3 -m venv "${PI_DIR}/.venv"
    fi
    source "${PI_DIR}/.venv/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "${PI_DIR}/requirements.txt"
    deactivate
}

install_services() {
    log "Installing systemd services..."
    chmod +x "${SCRIPT_DIR}/smartcane_network.sh"
    chmod +x "${SCRIPT_DIR}/diagnose.sh"
    chmod +x "${SCRIPT_DIR}/test_connection.sh"
    chmod +x "${SCRIPT_DIR}/reset_network.sh"
    
    sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" \
        "${SCRIPT_DIR}/systemd/smartcane-network-bootstrap.service" \
        > /etc/systemd/system/smartcane-network-bootstrap.service
    
    sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" \
        "${SCRIPT_DIR}/systemd/smartcane-runtime.service" \
        > /etc/systemd/system/smartcane-runtime.service
    
    install -m 644 "${SCRIPT_DIR}/systemd/smartcane-watchdog.service" \
        /etc/systemd/system/smartcane-watchdog.service
    
    chmod 644 /etc/systemd/system/smartcane-*.service
    
    cat > /etc/sudoers.d/smartcane-runtime <<EOF
pi ALL=(root) NOPASSWD: ${SCRIPT_DIR}/smartcane_network.sh
pi ALL=(root) NOPASSWD: ${SCRIPT_DIR}/reset_network.sh
EOF
    chmod 440 /etc/sudoers.d/smartcane-runtime
    
    systemctl daemon-reload
    systemctl enable smartcane-network-bootstrap.service
    systemctl enable smartcane-runtime.service
    systemctl enable smartcane-watchdog.service
}

configure_ap() {
    log "Configuring access point mode..."
    "${SCRIPT_DIR}/smartcane_network.sh" auto
}

start_services() {
    log "Starting SmartCane services..."
    systemctl restart smartcane-network-bootstrap.service
    systemctl restart smartcane-runtime.service
    systemctl restart smartcane-watchdog.service
}

print_status() {
    log "=== Setup Complete ==="
    log "SSID: SmartCane"
    log "Password: SmartCane123"
    log "Pi IP: 192.168.4.1"
    log "WebSocket: ws://192.168.4.1:8080/ws"
    echo
    log "Commands:"
    log "  Check status: ${SCRIPT_DIR}/smartcane_network.sh status"
    log "  Diagnose:     ${SCRIPT_DIR}/diagnose.sh"
    log "  Test conn:    ${SCRIPT_DIR}/test_connection.sh"
    log "  Reset:        sudo ${SCRIPT_DIR}/reset_network.sh"
    log "  View logs:    journalctl -u smartcane-runtime -f"
}

if [[ ${EUID} -ne 0 ]]; then
    fail "Run as root: sudo $0"
fi

log "Starting SmartCane Pi setup..."
install_packages
setup_python_venv
install_services
configure_ap
start_services
print_status
