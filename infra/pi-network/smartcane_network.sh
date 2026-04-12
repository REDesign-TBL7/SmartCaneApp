#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
WLAN_IFACE="${WLAN_IFACE:-wlan0}"
STATE_DIR="/etc/smartcane"
MODE_FILE="${STATE_DIR}/network_mode"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
DHCPCD_MARKER="# smartcane-ap"
WPA_SUPPLICANT_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
HOSTAPD_DEFAULT_CONF="/etc/default/hostapd"
BACKUP_ROOT="${STATE_DIR}/backups"
AP_TEST_STATE_FILE="${STATE_DIR}/ap_test.env"
ROLLBACK_UNIT="smartcane-ap-rollback"
AP_SSID="${SMARTCANE_AP_SSID:-SmartCane}"
AP_PASSPHRASE="${SMARTCANE_AP_PASSPHRASE:-SmartCane123}"
AP_CHANNEL="${SMARTCANE_AP_CHANNEL:-1}"
AP_COUNTRY="${SMARTCANE_AP_COUNTRY:-SG}"
AP_SUBNET_CIDR="${SMARTCANE_AP_SUBNET_CIDR:-192.168.4.1/24}"
AP_TEST_DEFAULT_TIMEOUT="${SMARTCANE_AP_TEST_TIMEOUT:-300}"
RUNTIME_SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-runtime.service"
RUNTIME_SERVICE_DEST="/etc/systemd/system/smartcane-runtime.service"
BOOTSTRAP_SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-network-bootstrap.service"
BOOTSTRAP_SERVICE_DEST="/etc/systemd/system/smartcane-network-bootstrap.service"
SUDOERS_DEST="/etc/sudoers.d/smartcane-runtime"

usage() {
  cat <<EOF
Usage:
  sudo $0 install
  sudo $0 auto
  sudo $0 ap
  sudo $0 ap-test [--rollback seconds]
  sudo $0 confirm-test
  sudo $0 rollback-now
  $0 status
EOF
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root: sudo $0 $*"
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  local package_hint="$2"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command '${command_name}'. Install package '${package_hint}' first."
    exit 1
  fi
}

require_runtime_tools() {
  require_command hostapd hostapd
  require_command dnsmasq dnsmasq
  require_command iw iw
  require_command rfkill rfkill
  require_command ip iproute2
  require_command systemctl systemd
}

service_installed() {
  local service_name="$1"
  systemctl cat "${service_name}" >/dev/null 2>&1
}

record_mode() {
  mkdir -p "${STATE_DIR}"
  cat >"${MODE_FILE}" <<EOF
SMARTCANE_NETWORK_MODE=PI_ACCESS_POINT
SMARTCANE_AP_SSID=${AP_SSID}
SMARTCANE_AP_IP=192.168.4.1
EOF
}

record_client_mode() {
  mkdir -p "${STATE_DIR}"
  cat >"${MODE_FILE}" <<EOF
SMARTCANE_NETWORK_MODE=CLIENT_RESTORED
SMARTCANE_RESTORED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

ensure_dhcpcd_conf() {
  if [[ ! -f "${DHCPCD_CONF}" ]]; then
    echo "Missing ${DHCPCD_CONF}. This script expects dhcpcd-managed networking."
    exit 1
  fi
}

replace_ap_dhcpcd_block() {
  ensure_dhcpcd_conf

  local tmp_file
  tmp_file=$(mktemp)
  awk -v marker="${DHCPCD_MARKER}" '
    BEGIN { skip=0 }
    $0 == marker { skip=1; next }
    skip == 1 && /^$/ { skip=0; next }
    skip == 0 { print }
  ' "${DHCPCD_CONF}" >"${tmp_file}"

  cat >>"${tmp_file}" <<EOF

${DHCPCD_MARKER}
interface ${WLAN_IFACE}
  static ip_address=${AP_SUBNET_CIDR}
  nohook wpa_supplicant
EOF

  cp "${tmp_file}" "${DHCPCD_CONF}"
  rm -f "${tmp_file}"
}

remove_ap_dhcpcd_block() {
  ensure_dhcpcd_conf

  local tmp_file
  tmp_file=$(mktemp)
  awk -v marker="${DHCPCD_MARKER}" '
    BEGIN { skip=0 }
    $0 == marker { skip=1; next }
    skip == 1 && /^$/ { skip=0; next }
    skip == 0 { print }
  ' "${DHCPCD_CONF}" >"${tmp_file}"

  cp "${tmp_file}" "${DHCPCD_CONF}"
  rm -f "${tmp_file}"
}

copy_if_exists() {
  local source_path="$1"
  local destination_path="$2"
  if [[ -f "${source_path}" ]]; then
    cp "${source_path}" "${destination_path}"
  fi
}

capture_service_enabled_state() {
  local service_name="$1"
  systemctl is-enabled "${service_name}" 2>/dev/null || echo "not-found"
}

capture_service_active_state() {
  local service_name="$1"
  systemctl is-active "${service_name}" 2>/dev/null || echo "inactive"
}

load_ap_test_state() {
  if [[ ! -f "${AP_TEST_STATE_FILE}" ]]; then
    return 1
  fi

  # shellcheck disable=SC1090
  source "${AP_TEST_STATE_FILE}"
  [[ -n "${BACKUP_DIR:-}" ]]
}

save_ap_test_state() {
  local rollback_seconds="$1"
  local backup_dir="$2"
  mkdir -p "${STATE_DIR}"

  cat >"${AP_TEST_STATE_FILE}" <<EOF
BACKUP_DIR='${backup_dir}'
ROLLBACK_SECONDS='${rollback_seconds}'
CREATED_AT='$(date -u +"%Y-%m-%dT%H:%M:%SZ")'
WPA_SUPPLICANT_SERVICE_ENABLED='$(capture_service_enabled_state "wpa_supplicant.service")'
WPA_SUPPLICANT_SERVICE_ACTIVE='$(capture_service_active_state "wpa_supplicant.service")'
WPA_SUPPLICANT_IFACE_ENABLED='$(capture_service_enabled_state "wpa_supplicant@${WLAN_IFACE}")'
WPA_SUPPLICANT_IFACE_ACTIVE='$(capture_service_active_state "wpa_supplicant@${WLAN_IFACE}")'
EOF
}

backup_network_state() {
  local rollback_seconds="$1"
  local backup_dir
  backup_dir="${BACKUP_ROOT}/ap-test-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${backup_dir}"

  copy_if_exists "${DHCPCD_CONF}" "${backup_dir}/dhcpcd.conf"
  copy_if_exists "${WPA_SUPPLICANT_CONF}" "${backup_dir}/wpa_supplicant.conf"
  copy_if_exists "${HOSTAPD_CONF}" "${backup_dir}/hostapd.conf"
  copy_if_exists "${DNSMASQ_CONF}" "${backup_dir}/dnsmasq.conf"
  copy_if_exists "${HOSTAPD_DEFAULT_CONF}" "${backup_dir}/hostapd.default"

  save_ap_test_state "${rollback_seconds}" "${backup_dir}"
  echo "Saved client network backup to ${backup_dir}"
}

cancel_rollback_timer() {
  systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl stop "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

stop_rollback_timer_only() {
  systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
}

arm_rollback_timer() {
  local rollback_seconds="$1"
  require_command systemd-run systemd

  cancel_rollback_timer
  systemd-run \
    --unit="${ROLLBACK_UNIT}" \
    --description="SmartCane AP test rollback" \
    --on-active="${rollback_seconds}s" \
    "${SCRIPT_DIR}/smartcane_network.sh" rollback-now >/dev/null
  echo "Armed AP rollback timer for ${rollback_seconds} seconds"
}

restore_service_state() {
  local service_name="$1"
  local enabled_state="$2"
  local active_state="$3"

  case "${enabled_state}" in
    enabled|enabled-runtime|linked|linked-runtime|alias|indirect)
      systemctl enable "${service_name}" >/dev/null 2>&1 || true
      ;;
    masked)
      systemctl mask "${service_name}" >/dev/null 2>&1 || true
      ;;
    *)
      systemctl disable "${service_name}" >/dev/null 2>&1 || true
      ;;
  esac

  case "${active_state}" in
    active|activating|reloading)
      systemctl restart "${service_name}" >/dev/null 2>&1 || systemctl start "${service_name}" >/dev/null 2>&1 || true
      ;;
    *)
      systemctl stop "${service_name}" >/dev/null 2>&1 || true
      ;;
  esac
}

restore_client_network_state() {
  if ! load_ap_test_state; then
    echo "No pending AP test state found"
    return 1
  fi

  echo "Restoring client network state from ${BACKUP_DIR}"

  systemctl stop hostapd >/dev/null 2>&1 || true
  systemctl stop dnsmasq >/dev/null 2>&1 || true
  systemctl disable hostapd >/dev/null 2>&1 || true
  systemctl disable dnsmasq >/dev/null 2>&1 || true

  if [[ -f "${BACKUP_DIR}/dhcpcd.conf" ]]; then
    cp "${BACKUP_DIR}/dhcpcd.conf" "${DHCPCD_CONF}"
  else
    remove_ap_dhcpcd_block
  fi

  if [[ -f "${BACKUP_DIR}/wpa_supplicant.conf" ]]; then
    mkdir -p "$(dirname "${WPA_SUPPLICANT_CONF}")"
    cp "${BACKUP_DIR}/wpa_supplicant.conf" "${WPA_SUPPLICANT_CONF}"
  fi

  if [[ -f "${BACKUP_DIR}/hostapd.default" ]]; then
    cp "${BACKUP_DIR}/hostapd.default" "${HOSTAPD_DEFAULT_CONF}"
  fi

  if [[ -f "${BACKUP_DIR}/hostapd.conf" ]]; then
    cp "${BACKUP_DIR}/hostapd.conf" "${HOSTAPD_CONF}"
  else
    rm -f "${HOSTAPD_CONF}"
  fi

  if [[ -f "${BACKUP_DIR}/dnsmasq.conf" ]]; then
    cp "${BACKUP_DIR}/dnsmasq.conf" "${DNSMASQ_CONF}"
  else
    rm -f "${DNSMASQ_CONF}"
  fi

  rfkill unblock wifi || true
  ip link set "${WLAN_IFACE}" down >/dev/null 2>&1 || true
  ip addr flush dev "${WLAN_IFACE}" >/dev/null 2>&1 || true
  ip link set "${WLAN_IFACE}" up >/dev/null 2>&1 || true

  systemctl restart dhcpcd >/dev/null 2>&1 || true
  restore_service_state "wpa_supplicant.service" "${WPA_SUPPLICANT_SERVICE_ENABLED:-disabled}" "${WPA_SUPPLICANT_SERVICE_ACTIVE:-inactive}"
  restore_service_state "wpa_supplicant@${WLAN_IFACE}" "${WPA_SUPPLICANT_IFACE_ENABLED:-disabled}" "${WPA_SUPPLICANT_IFACE_ACTIVE:-inactive}"

  record_client_mode
}

restart_runtime_if_installed() {
  if ! service_installed "smartcane-runtime.service"; then
    echo "SmartCane runtime service not installed; skipping runtime restart"
    return 0
  fi

  systemctl restart smartcane-runtime.service >/dev/null 2>&1 || true
  if systemctl is-active --quiet smartcane-runtime.service; then
    echo "SmartCane runtime restarted"
  else
    echo "SmartCane runtime restart requested but service is not active"
  fi
}

reset_wifi_interface() {
  rfkill unblock wifi || true
  ip link set "${WLAN_IFACE}" down || true
  ip addr flush dev "${WLAN_IFACE}" || true
  ip link set "${WLAN_IFACE}" up || true
  iw reg set "${AP_COUNTRY}" || true
  iw dev "${WLAN_IFACE}" set power_save off || true
}

apply_ap_mode() {
  require_runtime_tools

  echo "[1/5] Stopping client-mode services"
  systemctl disable "wpa_supplicant@${WLAN_IFACE}" >/dev/null 2>&1 || true
  systemctl stop "wpa_supplicant@${WLAN_IFACE}" >/dev/null 2>&1 || true
  systemctl stop wpa_supplicant.service >/dev/null 2>&1 || true
  systemctl stop NetworkManager >/dev/null 2>&1 || true
  systemctl stop hostapd >/dev/null 2>&1 || true
  systemctl stop dnsmasq >/dev/null 2>&1 || true

  echo "[2/5] Resetting ${WLAN_IFACE}"
  reset_wifi_interface

  echo "[3/5] Writing AP configuration"
  cat >"${HOSTAPD_CONF}" <<EOF
country_code=${AP_COUNTRY}
driver=nl80211
interface=${WLAN_IFACE}
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
ieee80211d=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
  sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' "${HOSTAPD_DEFAULT_CONF}"

  cat >"${DNSMASQ_CONF}" <<EOF
interface=${WLAN_IFACE}
bind-interfaces
dhcp-range=192.168.4.20,192.168.4.200,255.255.255.0,24h
domain-needed
bogus-priv
EOF

  replace_ap_dhcpcd_block

  echo "[4/5] Starting AP services"
  systemctl enable dhcpcd >/dev/null 2>&1 || true
  systemctl restart dhcpcd
  systemctl unmask hostapd
  systemctl enable hostapd >/dev/null 2>&1
  systemctl enable dnsmasq >/dev/null 2>&1
  systemctl restart hostapd
  systemctl restart dnsmasq

  echo "[5/5] Recording SmartCane AP mode"
  record_mode
  echo "SmartCane AP active: SSID=${AP_SSID}, IP=192.168.4.1"
}

apply_ap_test_mode() {
  local rollback_seconds="$1"

  backup_network_state "${rollback_seconds}"
  arm_rollback_timer "${rollback_seconds}"

  if apply_ap_mode; then
    restart_runtime_if_installed
    echo "AP test mode active. Rollback will restore the previous client Wi-Fi after ${rollback_seconds} seconds unless the app confirms success."
    return 0
  fi

  echo "AP test setup failed, restoring previous client Wi-Fi immediately"
  restore_client_network_state || true
  cancel_rollback_timer
  rm -f "${AP_TEST_STATE_FILE}"
  return 1
}

confirm_ap_test() {
  if ! load_ap_test_state; then
    echo "No pending AP test to confirm"
    return 0
  fi

  cancel_rollback_timer
  rm -f "${AP_TEST_STATE_FILE}"
  echo "Confirmed AP test success; rollback cancelled and AP mode retained"
}

rollback_ap_test() {
  if ! load_ap_test_state; then
    echo "No pending AP test to roll back"
    return 0
  fi

  stop_rollback_timer_only
  restore_client_network_state
  rm -f "${AP_TEST_STATE_FILE}"
  echo "Rolled back AP test and restored previous client network settings"
}

auto_mode() {
  apply_ap_mode
}

print_status() {
  echo "=== SmartCane Pi network status ==="
  echo
  echo "Interface: ${WLAN_IFACE}"
  ip addr show "${WLAN_IFACE}" || true
  echo
  echo "Active SSID:"
  iw dev 2>/dev/null || true
  echo
  echo "Service status:"
  systemctl is-enabled hostapd 2>/dev/null || true
  systemctl is-active hostapd 2>/dev/null || true
  systemctl is-enabled dnsmasq 2>/dev/null || true
  systemctl is-active dnsmasq 2>/dev/null || true
  systemctl is-enabled dhcpcd 2>/dev/null || true
  systemctl is-active dhcpcd 2>/dev/null || true
  echo
  echo "rfkill:"
  rfkill list 2>/dev/null || true
  echo
  echo "SmartCane mode file:"
  if [[ -f "${MODE_FILE}" ]]; then
    cat "${MODE_FILE}"
  else
    echo "(not set)"
  fi
  echo
  echo "AP test rollback:"
  if load_ap_test_state; then
    echo "pending (created ${CREATED_AT}, rollback ${ROLLBACK_SECONDS}s, backup ${BACKUP_DIR})"
  else
    echo "none"
  fi
  systemctl is-active "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
}

install_services() {
  require_root install
  echo "[1/7] Installing Pi network packages"
  apt-get update
  apt-get install -y hostapd dnsmasq iw rfkill iproute2 dhcpcd5

  echo "[2/7] Installing systemd units for repo root ${REPO_ROOT}"
  sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" "${RUNTIME_SERVICE_SRC}" >"${RUNTIME_SERVICE_DEST}"
  sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" "${BOOTSTRAP_SERVICE_SRC}" >"${BOOTSTRAP_SERVICE_DEST}"

  echo "[3/7] Ensuring network script is executable"
  chmod +x "${SCRIPT_DIR}/smartcane_network.sh"

  echo "[4/7] Installing sudoers rule for the Pi runtime"
  cat >"${SUDOERS_DEST}" <<EOF
pi ALL=(root) NOPASSWD: ${SCRIPT_DIR}/smartcane_network.sh
EOF
  chmod 440 "${SUDOERS_DEST}"

  echo "[5/7] Reloading systemd"
  systemctl daemon-reload

  echo "[6/7] Enabling and restarting SmartCane services"
  systemctl enable smartcane-network-bootstrap.service
  systemctl restart smartcane-network-bootstrap.service
  systemctl enable smartcane-runtime.service
  systemctl restart smartcane-runtime.service

  echo "[7/7] Install complete"
}

COMMAND="${1:-}"
if [[ -z "${COMMAND}" ]]; then
  usage
  exit 1
fi
shift || true

case "${COMMAND}" in
  install)
    install_services
    ;;
  auto)
    require_root auto
    auto_mode
    ;;
  ap)
    require_root ap
    apply_ap_mode
    ;;
  ap-test)
    require_root ap-test
    rollback_seconds="${AP_TEST_DEFAULT_TIMEOUT}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --rollback)
          rollback_seconds="$2"
          shift 2
          ;;
        *)
          echo "Unknown option for ap-test: $1"
          exit 1
          ;;
      esac
    done
    apply_ap_test_mode "${rollback_seconds}"
    ;;
  confirm-test)
    require_root confirm-test
    confirm_ap_test
    ;;
  rollback-now)
    require_root rollback-now
    rollback_ap_test
    ;;
  status)
    print_status
    ;;
  *)
    usage
    exit 1
    ;;
esac
