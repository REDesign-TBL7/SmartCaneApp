#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${SMARTCANE_REPO_ROOT:-/home/pi/smartcane-pi}"
RUNTIME_DIR="${REPO_ROOT}/runtime"
LOG_FILE="${SMARTCANE_OTA_LOG:-/var/log/smartcane-ota.log}"
RUNTIME_SERVICE="${SMARTCANE_RUNTIME_SERVICE:-smartcane-runtime.service}"
MANIFEST_URL="${SMARTCANE_OTA_MANIFEST_URL:-}"
AUTH_TOKEN="${SMARTCANE_OTA_AUTH_TOKEN:-}"
AUTH_TOKEN_FILE="${SMARTCANE_OTA_AUTH_TOKEN_FILE:-}"
DOWNLOAD_ROOT="${SMARTCANE_OTA_DOWNLOAD_DIR:-/var/lib/smartcane/ota}"
SCRIPT_DIR="${REPO_ROOT}/infra/pi-network"

log() {
  local message="[SmartCane OTA] $*"
  echo "${message}"
  if [[ -n "${LOG_FILE}" ]]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ${message}" >> "${LOG_FILE}" || true
  fi
}

fail() {
  log "ERROR: $*"
  exit 1
}

sha256_file() {
  local path="$1"
  sha256sum "${path}" | awk '{print $1}'
}

redeploy_systemd_units() {
  log "Refreshing installed systemd units"
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
  systemctl daemon-reload
  systemctl enable "${RUNTIME_SERVICE}"
  systemctl enable smartcane-ota.timer
}

health_check_runtime() {
  sleep 5
  systemctl is-active --quiet "${RUNTIME_SERVICE}"
}

curl_args() {
  local -a args
  args=(-fsSL --connect-timeout 15 --retry 3 --retry-delay 2)
  if [[ -n "${AUTH_TOKEN_FILE}" && -r "${AUTH_TOKEN_FILE}" && -z "${AUTH_TOKEN}" ]]; then
    AUTH_TOKEN=$(tr -d '\r\n' < "${AUTH_TOKEN_FILE}")
  fi
  if [[ -n "${AUTH_TOKEN}" ]]; then
    args+=(-H "Authorization: Bearer ${AUTH_TOKEN}")
  fi
  printf '%s\n' "${args[@]}"
}

read_manifest_field() {
  local manifest_file="$1"
  local field_name="$2"
  python3 - "${manifest_file}" "${field_name}" <<'PY'
import json
import sys

manifest_file, field_name = sys.argv[1:]
with open(manifest_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(field_name, "")
if value is None:
    value = ""
print(value)
PY
}

replace_repo_root() {
  local new_root="$1"
  local backup_root="$2"

  systemctl stop "${RUNTIME_SERVICE}" || true
  rm -rf "${backup_root}"
  mv "${REPO_ROOT}" "${backup_root}"
  mv "${new_root}" "${REPO_ROOT}"
}

rollback_bundle() {
  local backup_root="$1"
  log "Rolling back OTA bundle"
  systemctl stop "${RUNTIME_SERVICE}" || true
  rm -rf "${REPO_ROOT}"
  mv "${backup_root}" "${REPO_ROOT}"
  redeploy_systemd_units
  systemctl restart "${RUNTIME_SERVICE}"
  if health_check_runtime; then
    log "Rollback complete; runtime recovered"
    return 0
  fi
  log "Rollback failed; runtime is still inactive"
  return 1
}

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root"
fi

if [[ ! -f "${RUNTIME_DIR}/requirements.txt" ]]; then
  fail "Runtime requirements missing at ${RUNTIME_DIR}/requirements.txt"
fi

if [[ -z "${MANIFEST_URL}" ]]; then
  log "No OTA manifest configured; skipping OTA"
  exit 0
fi

for required_command in curl python3 tar sha256sum systemctl; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    fail "Missing required command: ${required_command}"
  fi
done

mkdir -p "${DOWNLOAD_ROOT}"
work_dir=$(mktemp -d "${DOWNLOAD_ROOT}/session.XXXXXX")
manifest_file="${work_dir}/manifest.json"
bundle_file="${work_dir}/bundle.tar.gz"
staged_root="${work_dir}/staged"
backup_root="${DOWNLOAD_ROOT}/previous"
trap 'rm -rf "${work_dir}"' EXIT

log "Fetching OTA manifest from ${MANIFEST_URL}"
mapfile -t curl_cmd < <(curl_args)
curl "${curl_cmd[@]}" "${MANIFEST_URL}" -o "${manifest_file}"

target_version=$(read_manifest_field "${manifest_file}" "version")
bundle_url=$(read_manifest_field "${manifest_file}" "bundleUrl")
bundle_sha256=$(read_manifest_field "${manifest_file}" "bundleSha256")

[[ -n "${target_version}" ]] || fail "Manifest missing version"
[[ -n "${bundle_url}" ]] || fail "Manifest missing bundleUrl"
[[ -n "${bundle_sha256}" ]] || fail "Manifest missing bundleSha256"

current_version=""
if [[ -f "${REPO_ROOT}/VERSION" ]]; then
  current_version=$(tr -d '\r\n' < "${REPO_ROOT}/VERSION")
fi

log "Current version ${current_version:-unknown}"
log "Target version ${target_version}"

if [[ "${current_version}" == "${target_version}" ]]; then
  log "Already up to date"
  exit 0
fi

log "Downloading OTA bundle from ${bundle_url}"
curl "${curl_cmd[@]}" "${bundle_url}" -o "${bundle_file}"

downloaded_sha256=$(sha256_file "${bundle_file}")
if [[ "${downloaded_sha256}" != "${bundle_sha256}" ]]; then
  fail "Checksum mismatch for downloaded bundle"
fi

mkdir -p "${staged_root}"
tar -xzf "${bundle_file}" -C "${staged_root}"

[[ -f "${staged_root}/runtime/src/main.py" ]] || fail "Downloaded bundle is missing runtime/src/main.py"
[[ -f "${staged_root}/infra/pi-network/run_pi_runtime.sh" ]] || fail "Downloaded bundle is missing infra/pi-network/run_pi_runtime.sh"
[[ -d "${staged_root}/runtime/vendor" ]] || fail "Downloaded bundle is missing vendored Python dependencies"

mkdir -p "${staged_root}/runtime/logs"
if [[ -d "${REPO_ROOT}/runtime/logs" ]]; then
  cp -a "${REPO_ROOT}/runtime/logs/." "${staged_root}/runtime/logs/" || true
fi
chmod +x "${staged_root}/infra/pi-network/"*.sh

replace_repo_root "${staged_root}" "${backup_root}"
redeploy_systemd_units

log "Restarting ${RUNTIME_SERVICE}"
systemctl restart "${RUNTIME_SERVICE}"

if health_check_runtime; then
  rm -rf "${backup_root}"
  log "OTA update complete; runtime is active"
else
  log "Runtime failed to start after OTA update; attempting rollback"
  if rollback_bundle "${backup_root}"; then
    fail "OTA reverted to previous bundle after runtime start failure"
  fi
  fail "Runtime failed after OTA update and rollback"
fi
