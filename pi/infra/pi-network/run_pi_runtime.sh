#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)
RUNTIME_DIR="${REPO_ROOT}/runtime"
MAIN_FILE="${RUNTIME_DIR}/src/main.py"
VENV_PYTHON="${RUNTIME_DIR}/.venv/bin/python"

fail() {
  echo "[SmartCane ERROR] $*" >&2
  exit 1
}

if [[ -x "${VENV_PYTHON}" ]]; then
  PYTHON_BIN="${VENV_PYTHON}"
else
  PYTHON_BIN=$(command -v python3 || true)
  [[ -n "${PYTHON_BIN}" ]] || fail "python3 is not installed"
  if [[ -d "${RUNTIME_DIR}/vendor" ]]; then
    export PYTHONPATH="${RUNTIME_DIR}/vendor${PYTHONPATH:+:${PYTHONPATH}}"
  fi
fi

cd "${RUNTIME_DIR}"
rfkill unblock bluetooth >/dev/null 2>&1 || true
systemctl start bluetooth >/dev/null 2>&1 || true
exec "${PYTHON_BIN}" "${MAIN_FILE}" "$@"
