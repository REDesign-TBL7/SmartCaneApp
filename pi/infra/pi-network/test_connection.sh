#!/usr/bin/env bash
set -euo pipefail

# PI_IP can be set explicitly. Falls back to mDNS hostname (works once the Pi
# is on the same network as the test machine via the phone hotspot).
PI_IP="${PI_IP:-smartcane-pi.local}"
WS_PORT="${WS_PORT:-8080}"

log() { echo "[Test] $*"; }

log "Testing connectivity to SmartCane Pi at ${PI_IP}:${WS_PORT}"
log "(Set PI_IP=<address> to override)"

log "1. Ping test..."
if ping -c 1 -W 2 "${PI_IP}" &>/dev/null; then
    log "PING OK"
else
    log "PING FAILED - check Pi is connected to the same hotspot as this machine"
    exit 1
fi

log "2. TCP port test..."
if timeout 3 bash -c "echo > /dev/tcp/${PI_IP}/${WS_PORT}" 2>/dev/null; then
    log "TCP ${WS_PORT} OK"
else
    log "TCP ${WS_PORT} FAILED - smartcane-runtime may not be running"
    exit 1
fi

log "3. WebSocket test..."
if command -v websocat &>/dev/null; then
    echo '{"type":"DEBUG_PING","debugLabel":"test"}' | timeout 5 websocat "ws://${PI_IP}:${WS_PORT}/ws" 2>/dev/null | grep -q DEBUG_PONG && log "WebSocket OK" || log "WebSocket FAILED"
elif command -v python3 &>/dev/null; then
    python3 <<EOF
import socket
import json
sock = socket.socket()
sock.settimeout(3)
try:
    sock.connect(("${PI_IP}", ${WS_PORT}))
    import websocket
    ws = websocket.create_connection("ws://${PI_IP}:${WS_PORT}/ws", timeout=3)
    ws.send(json.dumps({"type": "DEBUG_PING", "debugLabel": "test"}))
    result = ws.recv()
    if "DEBUG_PONG" in result:
        print("[Test] WebSocket OK")
    ws.close()
except Exception as e:
    print(f"[Test] WebSocket test error: {e}")
    exit(1)
EOF
else
    log "Skip WebSocket test (install websocat or websocket-client)"
fi

log "All basic tests passed!"
