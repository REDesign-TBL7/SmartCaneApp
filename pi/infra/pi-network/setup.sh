#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
RUNTIME_DIR="${REPO_ROOT}/runtime"
OTA_MANIFEST_URL="${SMARTCANE_OTA_MANIFEST_URL:-}"

log() { echo "[SmartCane] $*"; }
fail() { echo "[SmartCane ERROR] $*" >&2; exit 1; }

derive_manifest_url_from_repo_url() {
    local repo_url="$1"
    local normalized="$repo_url"
    normalized="${normalized%.git}"
    normalized="${normalized#git@github.com:}"
    normalized="${normalized#ssh://git@github.com/}"
    normalized="${normalized#https://github.com/}"
    normalized="${normalized#http://github.com/}"
    if [[ "${normalized}" == "${repo_url}" && "${repo_url}" != *github.com* ]]; then
        return 1
    fi
    printf 'https://github.com/%s/releases/download/pi-latest/smartcane-pi-manifest.json\n' "${normalized}"
}

install_packages() {
    log "Installing required packages (this may take a few minutes)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl git iw rfkill iproute2 network-manager avahi-daemon avahi-utils libnss-mdns bluez openssh-server python3-venv i2c-tools python3-picamera2
}

find_boot_config() {
    local candidate
    for candidate in /boot/firmware/config.txt /boot/config.txt; do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

ensure_line_in_file() {
    local file_path="$1"
    local line="$2"
    touch "${file_path}"
    if ! grep -Fxq "${line}" "${file_path}"; then
        printf '%s\n' "${line}" >> "${file_path}"
    fi
}

enable_i2c_support() {
    log "Enabling Pi I2C support for handle IMU..."
    local boot_config=""
    boot_config=$(find_boot_config || true)
    if [[ -n "${boot_config}" ]]; then
        if grep -Eq '^\s*dtparam=i2c_arm=' "${boot_config}"; then
            sed -i.bak 's/^\s*dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "${boot_config}"
        else
            printf '\n%s\n' "dtparam=i2c_arm=on" >> "${boot_config}"
        fi
        if grep -Eq '^\s*camera_auto_detect=' "${boot_config}"; then
            sed -i.bak 's/^\s*camera_auto_detect=.*/camera_auto_detect=1/' "${boot_config}"
        else
            printf '%s\n' "camera_auto_detect=1" >> "${boot_config}"
        fi
    fi

    ensure_line_in_file /etc/modules "i2c-dev"
    modprobe i2c-dev >/dev/null 2>&1 || true
}

setup_python_venv() {
    log "Setting up Python virtual environment..."
    if [[ ! -d "${RUNTIME_DIR}/.venv" ]]; then
        python3 -m venv "${RUNTIME_DIR}/.venv"
    fi
    source "${RUNTIME_DIR}/.venv/bin/activate"
    pip install --quiet --upgrade pip
    pip install --quiet -r "${RUNTIME_DIR}/requirements.txt"
    deactivate
}

install_services() {
    log "Installing systemd services..."
    local ota_manifest_url="${OTA_MANIFEST_URL}"
    if [[ -z "${ota_manifest_url}" ]]; then
        local origin_url=""
        origin_url=$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)
        if [[ -n "${origin_url}" ]]; then
            ota_manifest_url=$(derive_manifest_url_from_repo_url "${origin_url}" || true)
        fi
    fi

    chmod +x "${SCRIPT_DIR}/ota_update.sh"
    chmod +x "${SCRIPT_DIR}/generate_cloud_init.sh"
    chmod +x "${SCRIPT_DIR}/run_pi_runtime.sh"
    chmod +x "${SCRIPT_DIR}/diagnose.sh"
    chmod +x "${SCRIPT_DIR}/test_connection.sh"
    
    sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" \
        "${SCRIPT_DIR}/systemd/smartcane-runtime.service" \
        > /etc/systemd/system/smartcane-runtime.service
    sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" \
        "${SCRIPT_DIR}/systemd/smartcane-ota.service" \
        > /etc/systemd/system/smartcane-ota.service
    cp "${SCRIPT_DIR}/systemd/smartcane-ota.timer" /etc/systemd/system/smartcane-ota.timer
    
    chmod 644 /etc/systemd/system/smartcane-runtime.service
    chmod 644 /etc/systemd/system/smartcane-ota.service
    chmod 644 /etc/systemd/system/smartcane-ota.timer

    cat > /etc/default/smartcane-ota <<EOF
SMARTCANE_REPO_ROOT=${REPO_ROOT}
SMARTCANE_OTA_MANIFEST_URL=${ota_manifest_url}
EOF
    chmod 644 /etc/default/smartcane-ota
    
    systemctl daemon-reload
    systemctl enable smartcane-runtime.service
    systemctl enable smartcane-ota.timer
}

start_service() {
    log "Starting SmartCane service..."
    rfkill unblock bluetooth || true
    systemctl enable bluetooth
    systemctl restart bluetooth || true
    systemctl enable NetworkManager
    systemctl start NetworkManager || true
    systemctl enable avahi-daemon
    systemctl start avahi-daemon || true
    systemctl enable ssh || true
    systemctl restart ssh || true
    systemctl start smartcane-runtime.service
    sleep 3
}

print_status() {
    log "=== Setup Complete ==="
    log "Place hotspot credentials on the boot partition as smartcane-hotspot.json"
    log "Example:"
    log '  {"hotspotSSID":"Your iPhone","hotspotPassword":"your-password"}'
    log "Then boot the Pi with iPhone Personal Hotspot enabled."
    log "The runtime service will import that file, join the hotspot, advertise BLE diagnostics, and listen on ws://<pi-hotspot-ip>:8080/ws."
    echo
    log "Commands:"
    log "  SSH:          ssh pi@<pi-ip>"
    log "  Check status: sudo systemctl status smartcane-runtime"
    log "  View logs:    journalctl -u smartcane-runtime -f"
    log "  Restart:      sudo systemctl restart smartcane-runtime"
    log "  Reload:       sudo systemctl reload smartcane-runtime"
    log "  OTA now:      sudo systemctl start smartcane-ota.service"
    log "  OTA logs:     tail -f /var/log/smartcane-ota.log"
}

if [[ ${EUID} -ne 0 ]]; then
    fail "Run as root: sudo $0"
fi

log "Starting SmartCane Pi setup..."
install_packages
enable_i2c_support
setup_python_venv
install_services
log "Setup done, starting service..."
start_service
print_status
