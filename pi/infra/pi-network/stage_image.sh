#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)

ROOT_MOUNT=""
BOOT_MOUNT=""
HOTSPOT_SSID=""
HOTSPOT_PASSWORD=""
REPO_ON_PI="/home/pi/smartcane-pi"
OTA_MANIFEST_URL=""

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

find_boot_config_in_mount() {
  local boot_root="$1"
  local candidate
  for candidate in "${boot_root}/firmware/config.txt" "${boot_root}/config.txt"; do
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

usage() {
  cat <<EOF
Usage:
  $0 --root /path/to/rootfs --boot /path/to/boot [--repo-on-pi /home/pi/smartcane-pi] [--ota-manifest-url https://.../smartcane-pi-manifest.json] [--hotspot-ssid "iPhone"] [--hotspot-password "secret"]

What it does:
  - stages smartcane-runtime.service into the mounted Pi root filesystem
  - stages smartcane-ota.service and smartcane-ota.timer into the mounted Pi root filesystem
  - enables the service for first boot by creating the multi-user target symlink
  - optionally stages smartcane-hotspot.json into the mounted boot partition

Requirements:
  - the Pi image already contains the repo at --repo-on-pi
  - the Pi image already contains runtime/.venv and Python dependencies
EOF
}

fail() {
  echo "[SmartCane ERROR] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_MOUNT="$2"
      shift 2
      ;;
    --boot)
      BOOT_MOUNT="$2"
      shift 2
      ;;
    --repo-on-pi)
      REPO_ON_PI="$2"
      shift 2
      ;;
    --ota-manifest-url)
      OTA_MANIFEST_URL="$2"
      shift 2
      ;;
    --hotspot-ssid)
      HOTSPOT_SSID="$2"
      shift 2
      ;;
    --hotspot-password)
      HOTSPOT_PASSWORD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${ROOT_MOUNT}" ]] || fail "--root is required"
[[ -d "${ROOT_MOUNT}" ]] || fail "Root mount does not exist: ${ROOT_MOUNT}"
[[ -f "${ROOT_MOUNT}/etc/os-release" ]] || fail "Root mount does not look like a Pi rootfs: ${ROOT_MOUNT}"

if [[ -z "${OTA_MANIFEST_URL}" ]]; then
  origin_url=$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)
  if [[ -n "${origin_url}" ]]; then
    OTA_MANIFEST_URL=$(derive_manifest_url_from_repo_url "${origin_url}" || true)
  fi
fi

if [[ -n "${HOTSPOT_SSID}" || -n "${HOTSPOT_PASSWORD}" ]]; then
  [[ -n "${BOOT_MOUNT}" ]] || fail "--boot is required when staging hotspot credentials"
  [[ -d "${BOOT_MOUNT}" ]] || fail "Boot mount does not exist: ${BOOT_MOUNT}"
  [[ -n "${HOTSPOT_SSID}" && -n "${HOTSPOT_PASSWORD}" ]] || fail "Both --hotspot-ssid and --hotspot-password are required together"
fi
SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-runtime.service"
OTA_SERVICE_SRC="${SCRIPT_DIR}/systemd/smartcane-ota.service"
OTA_TIMER_SRC="${SCRIPT_DIR}/systemd/smartcane-ota.timer"
SERVICE_DEST_DIR="${ROOT_MOUNT}/etc/systemd/system"
SERVICE_DEST="${SERVICE_DEST_DIR}/smartcane-runtime.service"
WANTS_DIR="${SERVICE_DEST_DIR}/multi-user.target.wants"
SERVICE_LINK="${WANTS_DIR}/smartcane-runtime.service"
OTA_SERVICE_DEST="${SERVICE_DEST_DIR}/smartcane-ota.service"
OTA_TIMER_DEST="${SERVICE_DEST_DIR}/smartcane-ota.timer"
TIMERS_WANTS_DIR="${SERVICE_DEST_DIR}/timers.target.wants"
OTA_TIMER_LINK="${TIMERS_WANTS_DIR}/smartcane-ota.timer"
OTA_ENV_DEST="${ROOT_MOUNT}/etc/default/smartcane-ota"

mkdir -p "${SERVICE_DEST_DIR}" "${WANTS_DIR}" "${TIMERS_WANTS_DIR}" "${ROOT_MOUNT}/etc/default"
sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ON_PI}|g" "${SERVICE_SRC}" > "${SERVICE_DEST}"
sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ON_PI}|g" "${OTA_SERVICE_SRC}" > "${OTA_SERVICE_DEST}"
cp "${OTA_TIMER_SRC}" "${OTA_TIMER_DEST}"
chmod 644 "${SERVICE_DEST}"
chmod 644 "${OTA_SERVICE_DEST}" "${OTA_TIMER_DEST}"
ln -sfn "../smartcane-runtime.service" "${SERVICE_LINK}"
ln -sfn "../smartcane-ota.timer" "${OTA_TIMER_LINK}"
cat > "${OTA_ENV_DEST}" <<EOF
SMARTCANE_REPO_ROOT=${REPO_ON_PI}
SMARTCANE_OTA_MANIFEST_URL=${OTA_MANIFEST_URL}
EOF
ensure_line_in_file "${ROOT_MOUNT}/etc/modules" "i2c-dev"

echo "[SmartCane] Staged smartcane-runtime.service into ${SERVICE_DEST}"
echo "[SmartCane] Enabled smartcane-runtime.service for first boot"
echo "[SmartCane] Staged smartcane-ota.service and enabled smartcane-ota.timer"

if [[ -n "${BOOT_MOUNT}" && -n "${HOTSPOT_SSID}" ]]; then
  cat > "${BOOT_MOUNT}/smartcane-hotspot.json" <<EOF
{
  "hotspotSSID": "${HOTSPOT_SSID}",
  "hotspotPassword": "${HOTSPOT_PASSWORD}"
}
EOF
  echo "[SmartCane] Wrote ${BOOT_MOUNT}/smartcane-hotspot.json"
fi

if [[ -n "${BOOT_MOUNT}" ]]; then
  touch "${BOOT_MOUNT}/ssh"
  boot_config_path=$(find_boot_config_in_mount "${BOOT_MOUNT}" || true)
  if [[ -n "${boot_config_path}" ]]; then
    if grep -Eq '^\s*dtparam=i2c_arm=' "${boot_config_path}"; then
      sed -i.bak 's/^\s*dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "${boot_config_path}"
    else
      printf '\n%s\n' "dtparam=i2c_arm=on" >> "${boot_config_path}"
    fi
  fi
fi

cat <<EOF
[SmartCane] Offline staging complete.

First boot assumptions:
  - repo exists at ${REPO_ON_PI}
  - runtime venv exists at ${REPO_ON_PI}/runtime/.venv
  - required OS packages are already on the image
EOF
