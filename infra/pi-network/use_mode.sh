#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 ap | hotspot --ssid <name> --psk <password>"
  exit 1
fi

MODE="$1"
shift

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

case "${MODE}" in
  ap)
    sudo "${SCRIPT_DIR}/setup_ap_mode.sh"
    ;;
  hotspot)
    sudo "${SCRIPT_DIR}/setup_hotspot_client_mode.sh" "$@"
    ;;
  *)
    echo "Unknown mode: ${MODE}. Use 'ap' or 'hotspot'."
    exit 1
    ;;
esac

"${SCRIPT_DIR}/check_network_mode.sh"
