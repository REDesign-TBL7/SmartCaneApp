#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PI_BUNDLE_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)

SOURCE_DIR="${PI_BUNDLE_ROOT}"
OUTPUT_DIR=""
VERSION=""
BUNDLE_URL=""
PUBLISHED_AT=""
WHEELHOUSE=""
PI_PYTHON_VERSION="${SMARTCANE_PI_PYTHON_VERSION:-313}"
BUNDLE_NAME="smartcane-pi-bundle.tar.gz"
MANIFEST_NAME="smartcane-pi-manifest.json"
CHECKSUM_NAME="smartcane-pi-sha256.txt"

usage() {
  cat <<EOF
Usage:
  $0 --output-dir /path/to/dist --version 20260412-abcdef0 [--source-dir /path/to/pi] [--bundle-url https://.../smartcane-pi-bundle.tar.gz] [--published-at 2026-04-12T12:00:00Z] [--wheelhouse /path/to/wheelhouse] [--pi-python-version 311]

Builds a deployable Pi OTA bundle containing:
  - runtime/
  - infra/
  - runtime/vendor/ vendored Python deps
  - VERSION
  - .smartcane-release.json
EOF
}

fail() {
  echo "[SmartCane ERROR] $*" >&2
  exit 1
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
    return
  fi
  shasum -a 256 "${path}" | awk '{print $1}'
}

prepare_wheelhouse() {
  if [[ -n "${WHEELHOUSE}" ]]; then
    [[ -d "${WHEELHOUSE}" ]] || fail "Wheelhouse directory does not exist: ${WHEELHOUSE}"
    echo "${WHEELHOUSE}"
    return
  fi

  local generated_wheelhouse
  generated_wheelhouse=$(mktemp -d "${TMPDIR:-/tmp}/smartcane-bundle-wheelhouse.XXXXXX")
  # Redirect pip output to stderr so only the path is captured by the caller.
  # Use manylinux_2_17_aarch64 (glibc 2.17+, covers Pi OS Bullseye/Bookworm) so
  # that packages like Pillow whose wheels are tagged manylinux rather than plain
  # linux_aarch64 are matched correctly.
  python3 -m pip download --disable-pip-version-check --only-binary=:all: \
    --platform manylinux_2_17_aarch64 \
    --python-version "${PI_PYTHON_VERSION}" \
    --implementation cp \
    --abi "cp${PI_PYTHON_VERSION}" \
    --dest "${generated_wheelhouse}" \
    -r "${SOURCE_DIR}/runtime/requirements.txt" >&2
  echo "${generated_wheelhouse}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --bundle-url)
      BUNDLE_URL="$2"
      shift 2
      ;;
    --published-at)
      PUBLISHED_AT="$2"
      shift 2
      ;;
    --wheelhouse)
      WHEELHOUSE="$2"
      shift 2
      ;;
    --pi-python-version)
      PI_PYTHON_VERSION="$2"
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

[[ -n "${OUTPUT_DIR}" ]] || fail "--output-dir is required"
[[ -n "${VERSION}" ]] || fail "--version is required"
[[ -d "${SOURCE_DIR}" ]] || fail "Source dir does not exist: ${SOURCE_DIR}"
[[ -d "${SOURCE_DIR}/runtime" ]] || fail "Missing ${SOURCE_DIR}/runtime"
[[ -d "${SOURCE_DIR}/infra" ]] || fail "Missing ${SOURCE_DIR}/infra"
[[ -f "${SOURCE_DIR}/runtime/requirements.txt" ]] || fail "Missing ${SOURCE_DIR}/runtime/requirements.txt"

if [[ -z "${PUBLISHED_AT}" ]]; then
  PUBLISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

mkdir -p "${OUTPUT_DIR}"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/smartcane-pi-bundle.XXXXXX")
cleanup_wheelhouse=0
wheelhouse_dir=""
trap 'rm -rf "${workspace}"; if [[ ${cleanup_wheelhouse} -eq 1 && -n "${wheelhouse_dir}" ]]; then rm -rf "${wheelhouse_dir}"; fi' EXIT

stage_dir="${workspace}/stage"
mkdir -p "${stage_dir}"

python3 - "${SOURCE_DIR}" "${stage_dir}" <<'PY'
import os
import shutil
import sys

source_dir, stage_dir = sys.argv[1:]

exclude_dir_names = {
    ".git",
    ".venv",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "DerivedData",
    "node_modules",
    "logs",
}
exclude_suffixes = (".pyc", ".pyo", ".DS_Store")

for top_level in ("runtime", "infra"):
    src_root = os.path.join(source_dir, top_level)
    dest_root = os.path.join(stage_dir, top_level)
    for root, dirs, files in os.walk(src_root):
        dirs[:] = [d for d in dirs if d not in exclude_dir_names]
        rel_root = os.path.relpath(root, src_root)
        target_root = dest_root if rel_root == "." else os.path.join(dest_root, rel_root)
        os.makedirs(target_root, exist_ok=True)
        for filename in files:
            if filename.endswith(exclude_suffixes):
                continue
            shutil.copy2(os.path.join(root, filename), os.path.join(target_root, filename))
PY

mkdir -p "${stage_dir}/runtime/logs"

wheelhouse_dir=$(prepare_wheelhouse)
if [[ "${wheelhouse_dir}" != "${WHEELHOUSE}" ]]; then
  cleanup_wheelhouse=1
fi

python3 - "${wheelhouse_dir}" "${stage_dir}/runtime/vendor" <<'PY'
import os
import shutil
import sys
import zipfile

wheelhouse_dir, vendor_dir = sys.argv[1:]
os.makedirs(vendor_dir, exist_ok=True)

wheel_files = sorted(
    os.path.join(wheelhouse_dir, filename)
    for filename in os.listdir(wheelhouse_dir)
    if filename.endswith(".whl")
)
if not wheel_files:
    raise SystemExit("No wheel files found in wheelhouse")

for wheel_file in wheel_files:
    with zipfile.ZipFile(wheel_file) as archive:
        archive.extractall(vendor_dir)
PY

commit_sha="unknown"
if git -C "${SOURCE_DIR}" rev-parse HEAD >/dev/null 2>&1; then
  commit_sha=$(git -C "${SOURCE_DIR}" rev-parse HEAD)
fi

cat > "${stage_dir}/VERSION" <<EOF
${VERSION}
EOF

cat > "${stage_dir}/.smartcane-release.json" <<EOF
{
  "version": "${VERSION}",
  "publishedAt": "${PUBLISHED_AT}",
  "commit": "${commit_sha}",
  "bundleFileName": "${BUNDLE_NAME}"
}
EOF

bundle_path="${OUTPUT_DIR}/${BUNDLE_NAME}"
manifest_path="${OUTPUT_DIR}/${MANIFEST_NAME}"
checksum_path="${OUTPUT_DIR}/${CHECKSUM_NAME}"

tar -czf "${bundle_path}" -C "${stage_dir}" .
bundle_sha256=$(sha256_file "${bundle_path}")
printf '%s  %s\n' "${bundle_sha256}" "${BUNDLE_NAME}" > "${checksum_path}"

cat > "${manifest_path}" <<EOF
{
  "version": "${VERSION}",
  "publishedAt": "${PUBLISHED_AT}",
  "commit": "${commit_sha}",
  "bundleFileName": "${BUNDLE_NAME}",
  "bundleUrl": "${BUNDLE_URL}",
  "bundleSha256": "${bundle_sha256}"
}
EOF

echo "[SmartCane] Wrote ${bundle_path}"
echo "[SmartCane] Wrote ${checksum_path}"
echo "[SmartCane] Wrote ${manifest_path}"
