#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)

BOOT_DIR=""
SOURCE_REPO="${REPO_ROOT}"
REPO_URL=""
REPO_BRANCH="main"
REPO_ON_PI="/home/pi/smartcane-pi"
HOSTNAME="smartcane-pi"
PI_USERNAME="pi"
SSH_PASSWORD=""
WHEELHOUSE=""
MODE="offline"
PAYLOAD_DIR_NAME="smartcane"
HOTSPOT_SSID=""
HOTSPOT_PASSWORD=""
OTA_MANIFEST_URL=""
TOOL_PACKAGES=(
  curl
  git
  iw
  i2c-tools
  rfkill
  iproute2
  dhcpcd5
  wpasupplicant
  bluez
  python3-picamera2
  python3-venv
)

usage() {
  cat <<EOF
Usage:
  $0 --boot /path/to/boot [--mode offline|online] [--source-repo /path/to/REDesign/pi] [--repo-on-pi /home/pi/smartcane-pi] [--hostname smartcane-pi] [--repo-url https://github.com/owner/repo.git] [--repo-branch main] [--wheelhouse /path/to/wheelhouse] [--ota-manifest-url https://.../smartcane-pi-manifest.json] [--ssh-password "secret"] [--hotspot-ssid "iPhone"] [--hotspot-password "secret"]

Writes Raspberry Pi OS cloud-init files:
  - meta-data
  - user-data
  - network-config

Offline mode stages a first-boot payload on the boot partition:
  - smartcane/repo.tar.gz
  - smartcane/python-vendor.tar.gz

The offline first-boot flow will:
  - configure SSH password authentication
  - unpack the local repo from the boot partition
  - unpack vendored Python dependencies from the boot partition
  - install OS tool packages only if internet is already available
  - install and enable smartcane-runtime.service
  - install and enable smartcane-ota.timer

Online mode keeps the older clone-on-first-boot behavior and requires --repo-url.
OTA uses the Pi release manifest configured via --ota-manifest-url or derived from the GitHub repo URL.
EOF
}

fail() {
  echo "[SmartCane ERROR] $*" >&2
  exit 1
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

build_repo_archive() {
  local source_repo="$1"
  local output_archive="$2"
  local repo_dir_name="$3"

  python3 - "${source_repo}" "${output_archive}" "${repo_dir_name}" <<'PY'
import os
import sys
import tarfile

source_repo, output_archive, repo_dir_name = sys.argv[1:]

exclude_dir_names = {
    ".git",
    ".venv",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "DerivedData",
    "node_modules",
}
exclude_suffixes = (".pyc", ".pyo", ".DS_Store")

with tarfile.open(output_archive, "w:gz") as archive:
    for root, dirs, files in os.walk(source_repo):
        dirs[:] = [d for d in dirs if d not in exclude_dir_names]
        rel_root = os.path.relpath(root, source_repo)
        archive_root = repo_dir_name if rel_root == "." else os.path.join(repo_dir_name, rel_root)
        archive.add(root, arcname=archive_root, recursive=False)
        for filename in files:
            if filename.endswith(exclude_suffixes):
                continue
            full_path = os.path.join(root, filename)
            archive_name = os.path.join(archive_root, filename)
            archive.add(full_path, arcname=archive_name, recursive=False)
PY
}

prepare_wheelhouse() {
  if [[ -n "${WHEELHOUSE}" ]]; then
    [[ -d "${WHEELHOUSE}" ]] || fail "Wheelhouse directory does not exist: ${WHEELHOUSE}"
    echo "${WHEELHOUSE}"
    return
  fi

  local generated_wheelhouse
  generated_wheelhouse=$(mktemp -d "${TMPDIR:-/tmp}/smartcane-wheelhouse.XXXXXX")
  if ! python3 -m pip download --disable-pip-version-check --only-binary=:all: \
    --dest "${generated_wheelhouse}" \
    -r "${SOURCE_REPO}/runtime/requirements.txt"; then
    rm -rf "${generated_wheelhouse}"
    fail "Failed to build offline wheelhouse. Re-run with internet access on this machine or provide --wheelhouse."
  fi

  echo "${generated_wheelhouse}"
}

build_vendor_archive() {
  local wheelhouse_dir="$1"
  local output_archive="$2"

  python3 - "${wheelhouse_dir}" "${output_archive}" <<'PY'
import os
import shutil
import sys
import tarfile
import tempfile
import zipfile

wheelhouse_dir, output_archive = sys.argv[1:]
wheel_files = sorted(
    os.path.join(wheelhouse_dir, filename)
    for filename in os.listdir(wheelhouse_dir)
    if filename.endswith(".whl")
)
if not wheel_files:
    raise SystemExit("No wheel files found in wheelhouse")

workspace = tempfile.mkdtemp(prefix="smartcane_vendor_")
vendor_dir = os.path.join(workspace, "vendor")
os.makedirs(vendor_dir, exist_ok=True)

try:
    for wheel_file in wheel_files:
        with zipfile.ZipFile(wheel_file) as archive:
            archive.extractall(vendor_dir)

    with tarfile.open(output_archive, "w:gz") as archive:
        archive.add(vendor_dir, arcname="vendor")
finally:
    shutil.rmtree(workspace, ignore_errors=True)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot)
      BOOT_DIR="$2"
      shift 2
      ;;
    --source-repo)
      SOURCE_REPO="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --repo-branch)
      REPO_BRANCH="$2"
      shift 2
      ;;
    --repo-on-pi)
      REPO_ON_PI="$2"
      shift 2
      ;;
    --hostname)
      HOSTNAME="$2"
      shift 2
      ;;
    --ssh-password)
      SSH_PASSWORD="$2"
      shift 2
      ;;
    --wheelhouse)
      WHEELHOUSE="$2"
      shift 2
      ;;
    --ota-manifest-url)
      OTA_MANIFEST_URL="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
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

[[ -n "${BOOT_DIR}" ]] || fail "--boot is required"
[[ -d "${BOOT_DIR}" ]] || fail "Boot directory does not exist: ${BOOT_DIR}"
[[ -d "${SOURCE_REPO}" ]] || fail "Source repo does not exist: ${SOURCE_REPO}"
[[ -f "${SOURCE_REPO}/runtime/requirements.txt" ]] || fail "Source repo does not contain runtime/requirements.txt: ${SOURCE_REPO}"
[[ "${MODE}" == "offline" || "${MODE}" == "online" ]] || fail "--mode must be offline or online"
if [[ -n "${HOTSPOT_SSID}" || -n "${HOTSPOT_PASSWORD}" ]]; then
  [[ -n "${HOTSPOT_SSID}" && -n "${HOTSPOT_PASSWORD}" ]] || fail "Both --hotspot-ssid and --hotspot-password are required together"
fi
if [[ "${MODE}" == "online" ]]; then
  [[ -n "${REPO_URL}" ]] || fail "--repo-url is required in online mode"
fi
if [[ -z "${OTA_MANIFEST_URL}" ]]; then
  if [[ -n "${REPO_URL}" ]]; then
    OTA_MANIFEST_URL=$(derive_manifest_url_from_repo_url "${REPO_URL}" || true)
  else
    origin_url=$(git -C "${SOURCE_REPO}" config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "${origin_url}" ]]; then
      OTA_MANIFEST_URL=$(derive_manifest_url_from_repo_url "${origin_url}" || true)
    fi
  fi
fi

runtime_service=$(sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ON_PI}|g" "${SCRIPT_DIR}/systemd/smartcane-runtime.service")
ota_service=$(sed "s|__SMARTCANE_REPO_ROOT__|${REPO_ON_PI}|g" "${SCRIPT_DIR}/systemd/smartcane-ota.service")
ota_timer=$(cat "${SCRIPT_DIR}/systemd/smartcane-ota.timer")
tool_packages_string="${TOOL_PACKAGES[*]}"

ssh_password_block="ssh_pwauth: true"
if [[ -n "${SSH_PASSWORD}" ]]; then
  ssh_password_block=$(cat <<EOF
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: ${PI_USERNAME}
      password: ${SSH_PASSWORD}
      type: text
EOF
)
fi

cat > "${BOOT_DIR}/meta-data" <<EOF
instance-id: ${HOSTNAME}
local-hostname: ${HOSTNAME}
EOF

cat > "${BOOT_DIR}/network-config" <<EOF
version: 2
renderer: NetworkManager
EOF

if [[ -n "${HOTSPOT_SSID}" ]]; then
  cat > "${BOOT_DIR}/smartcane-hotspot.json" <<EOF
{
  "hotspotSSID": "${HOTSPOT_SSID}",
  "hotspotPassword": "${HOTSPOT_PASSWORD}"
}
EOF
fi

boot_config_path=$(find_boot_config_in_mount "${BOOT_DIR}" || true)
if [[ -n "${boot_config_path}" ]]; then
  if grep -Eq '^\s*dtparam=i2c_arm=' "${boot_config_path}"; then
    sed -i.bak 's/^\s*dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "${boot_config_path}"
  else
    printf '\n%s\n' "dtparam=i2c_arm=on" >> "${boot_config_path}"
  fi
fi

if [[ "${MODE}" == "offline" ]]; then
  payload_dir="${BOOT_DIR}/${PAYLOAD_DIR_NAME}"
  mkdir -p "${payload_dir}"

  repo_archive="${payload_dir}/repo.tar.gz"
  vendor_archive="${payload_dir}/python-vendor.tar.gz"
  repo_dir_name=$(basename "${REPO_ON_PI}")
  build_repo_archive "${SOURCE_REPO}" "${repo_archive}" "${repo_dir_name}"

  wheelhouse_dir=$(prepare_wheelhouse)
  cleanup_wheelhouse=0
  if [[ "${wheelhouse_dir}" != "${WHEELHOUSE}" ]]; then
    cleanup_wheelhouse=1
  fi
  build_vendor_archive "${wheelhouse_dir}" "${vendor_archive}"
  if [[ ${cleanup_wheelhouse} -eq 1 ]]; then
    rm -rf "${wheelhouse_dir}"
  fi

  firstboot_script=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail

BOOT_ROOT="/boot/firmware"
if [[ ! -d "\${BOOT_ROOT}/${PAYLOAD_DIR_NAME}" ]]; then
  BOOT_ROOT="/boot"
fi
PAYLOAD_DIR="\${BOOT_ROOT}/${PAYLOAD_DIR_NAME}"
REPO_PARENT="$(dirname "${REPO_ON_PI}")"
TOOL_PACKAGES=(${tool_packages_string})
FIRSTBOOT_LOG="\${PAYLOAD_DIR}/firstboot.log"

mkdir -p "\${PAYLOAD_DIR}"
exec >> "\${FIRSTBOOT_LOG}" 2>&1
echo "===== \$(date -u +"%Y-%m-%dT%H:%M:%SZ") SmartCane first boot start ====="

have_network_for_tools() {
  timeout 8 getent hosts deb.debian.org >/dev/null 2>&1
}

mkdir -p "\${REPO_PARENT}"
rm -rf "${REPO_ON_PI}"
tar -xzf "\${PAYLOAD_DIR}/repo.tar.gz" -C "\${REPO_PARENT}"
mkdir -p "${REPO_ON_PI}/runtime"
tar -xzf "\${PAYLOAD_DIR}/python-vendor.tar.gz" -C "${REPO_ON_PI}/runtime"
chmod +x "${REPO_ON_PI}/infra/pi-network/"*.sh

if [[ -f /etc/modules ]]; then
  grep -Fxq "i2c-dev" /etc/modules || printf '%s\n' "i2c-dev" >> /etc/modules
fi
modprobe i2c-dev >/dev/null 2>&1 || true

if command -v apt-get >/dev/null 2>&1; then
  if have_network_for_tools; then
    echo "Network detected for package install"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq "\${TOOL_PACKAGES[@]}" || true
  else
    echo "No package-install network detected; skipping apt install"
  fi
fi

systemctl enable bluetooth || true
systemctl restart bluetooth || true
systemctl daemon-reload
systemctl enable smartcane-runtime.service
systemctl enable smartcane-ota.timer || true
systemctl start smartcane-runtime.service
systemctl start smartcane-ota.timer || true
echo "===== \$(date -u +"%Y-%m-%dT%H:%M:%SZ") SmartCane first boot done ====="
EOF
)

  cat > "${BOOT_DIR}/user-data" <<EOF
#cloud-config
hostname: ${HOSTNAME}
manage_etc_hosts: true
${ssh_password_block}
users:
  - name: ${PI_USERNAME}
    groups: [adm, sudo, audio, video, plugdev, dialout, netdev]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
write_files:
  - path: /etc/systemd/system/smartcane-runtime.service
    permissions: '0644'
    content: |
$(printf '%s\n' "${runtime_service}" | sed 's/^/        /')
  - path: /etc/systemd/system/smartcane-ota.service
    permissions: '0644'
    content: |
$(printf '%s\n' "${ota_service}" | sed 's/^/        /')
  - path: /etc/systemd/system/smartcane-ota.timer
    permissions: '0644'
    content: |
$(printf '%s\n' "${ota_timer}" | sed 's/^/        /')
  - path: /etc/default/smartcane-ota
    permissions: '0644'
    content: |
      SMARTCANE_REPO_ROOT=${REPO_ON_PI}
      SMARTCANE_OTA_MANIFEST_URL=${OTA_MANIFEST_URL}
  - path: /usr/local/sbin/smartcane-firstboot.sh
    permissions: '0755'
    content: |
$(printf '%s\n' "${firstboot_script}" | sed 's/^/        /')
runcmd:
  - /usr/local/sbin/smartcane-firstboot.sh
EOF

  echo "[SmartCane] Wrote offline cloud-init files into ${BOOT_DIR}"
  echo "[SmartCane] Staged offline payload into ${payload_dir}"
else
  cat > "${BOOT_DIR}/user-data" <<EOF
#cloud-config
hostname: ${HOSTNAME}
manage_etc_hosts: true
package_update: true
packages:
  - curl
  - git
  - iw
  - rfkill
  - iproute2
  - dhcpcd5
  - wpasupplicant
  - bluez
  - python3-venv
users:
  - name: ${PI_USERNAME}
    groups: [adm, sudo, audio, video, plugdev, dialout, netdev]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
${ssh_password_block}
write_files:
  - path: /etc/systemd/system/smartcane-runtime.service
    permissions: '0644'
    content: |
$(printf '%s\n' "${runtime_service}" | sed 's/^/        /')
  - path: /etc/systemd/system/smartcane-ota.service
    permissions: '0644'
    content: |
$(printf '%s\n' "${ota_service}" | sed 's/^/        /')
  - path: /etc/systemd/system/smartcane-ota.timer
    permissions: '0644'
    content: |
$(printf '%s\n' "${ota_timer}" | sed 's/^/        /')
  - path: /etc/default/smartcane-ota
    permissions: '0644'
    content: |
      SMARTCANE_REPO_ROOT=${REPO_ON_PI}
      SMARTCANE_OTA_MANIFEST_URL=${OTA_MANIFEST_URL}
runcmd:
  - systemctl enable bluetooth
  - systemctl restart bluetooth || true
  - test -d ${REPO_ON_PI}/.git || git clone --branch ${REPO_BRANCH} ${REPO_URL} ${REPO_ON_PI}
  - python3 -m venv ${REPO_ON_PI}/runtime/.venv
  - ${REPO_ON_PI}/runtime/.venv/bin/pip install --upgrade pip
  - ${REPO_ON_PI}/runtime/.venv/bin/pip install -r ${REPO_ON_PI}/runtime/requirements.txt
  - chmod +x ${REPO_ON_PI}/infra/pi-network/ota_update.sh
  - chmod +x ${REPO_ON_PI}/infra/pi-network/run_pi_runtime.sh
  - systemctl daemon-reload
  - systemctl enable smartcane-runtime.service
  - systemctl enable smartcane-ota.timer
  - systemctl start smartcane-runtime.service
  - systemctl start smartcane-ota.timer
EOF

  echo "[SmartCane] Wrote online cloud-init files into ${BOOT_DIR}"
fi
