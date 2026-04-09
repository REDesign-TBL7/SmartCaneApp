#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-runtime.service"
SERVICE_DEST="/etc/systemd/system/smartcane-runtime.service"
BOOTSTRAP_SRC="${SCRIPT_DIR}/systemd/smartcane-network-bootstrap.service"
BOOTSTRAP_DEST="/etc/systemd/system/smartcane-network-bootstrap.service"
SUDOERS_DEST="/etc/sudoers.d/smartcane-runtime"

cp "${SERVICE_SRC}" "${SERVICE_DEST}"
cp "${BOOTSTRAP_SRC}" "${BOOTSTRAP_DEST}"
chmod +x "${SCRIPT_DIR}/setup_ap_mode.sh" "${SCRIPT_DIR}/setup_hotspot_client_mode.sh" "${SCRIPT_DIR}/bootstrap_network_mode.sh"
cat >"${SUDOERS_DEST}" <<EOF
pi ALL=(root) NOPASSWD: ${SCRIPT_DIR}/setup_hotspot_client_mode.sh, ${SCRIPT_DIR}/setup_ap_mode.sh
EOF
chmod 440 "${SUDOERS_DEST}"
systemctl daemon-reload
systemctl enable smartcane-network-bootstrap.service
systemctl restart smartcane-network-bootstrap.service
systemctl enable smartcane-runtime.service
systemctl restart smartcane-runtime.service

echo "Installed and started smartcane-runtime.service"
systemctl --no-pager --full status smartcane-runtime.service || true
