#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-runtime.service"
SERVICE_DEST="/etc/systemd/system/smartcane-runtime.service"
BOOTSTRAP_SRC="${SCRIPT_DIR}/systemd/smartcane-network-bootstrap.service"
BOOTSTRAP_DEST="/etc/systemd/system/smartcane-network-bootstrap.service"
SUDOERS_DEST="/etc/sudoers.d/smartcane-runtime"

echo "[1/8] Installing systemd unit files for repo root ${REPO_ROOT}"
sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" "${SERVICE_SRC}" >"${SERVICE_DEST}"
sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ROOT}|g" "${BOOTSTRAP_SRC}" >"${BOOTSTRAP_DEST}"

echo "[2/8] Ensuring network setup scripts are executable"
chmod +x "${SCRIPT_DIR}/setup_ap_mode.sh" "${SCRIPT_DIR}/setup_hotspot_client_mode.sh" "${SCRIPT_DIR}/bootstrap_network_mode.sh"

echo "[3/8] Installing sudoers rule for Pi runtime helpers"
cat >"${SUDOERS_DEST}" <<EOF
pi ALL=(root) NOPASSWD: ${SCRIPT_DIR}/setup_hotspot_client_mode.sh, ${SCRIPT_DIR}/setup_ap_mode.sh
EOF

echo "[4/8] Locking down sudoers file permissions"
chmod 440 "${SUDOERS_DEST}"

echo "[5/8] Reloading systemd daemon"
systemctl daemon-reload

echo "[6/8] Enabling and restarting network bootstrap service"
systemctl enable smartcane-network-bootstrap.service
systemctl restart smartcane-network-bootstrap.service

echo "[7/8] Enabling and restarting SmartCane runtime service"
systemctl enable smartcane-runtime.service
systemctl restart smartcane-runtime.service

echo "[8/8] Install complete"
echo "Installed and started smartcane-runtime.service using repo root ${REPO_ROOT}"
systemctl --no-pager --full status smartcane-runtime.service || true
