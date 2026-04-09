#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-runtime.service"
SERVICE_DEST="/etc/systemd/system/smartcane-runtime.service"

cp "${SERVICE_SRC}" "${SERVICE_DEST}"
systemctl daemon-reload
systemctl enable smartcane-runtime.service
systemctl restart smartcane-runtime.service

echo "Installed and started smartcane-runtime.service"
systemctl --no-pager --full status smartcane-runtime.service || true
