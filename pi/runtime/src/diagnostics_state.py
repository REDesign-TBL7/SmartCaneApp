import threading
from collections import deque


class DiagnosticsState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._stage_code = "BO"
        self._last_error_code = "NO"
        self._recent_codes: deque[str] = deque(["BO"], maxlen=6)
        self._recent_messages: deque[str] = deque(maxlen=12)
        self._connected_clients = 0
        self._runtime_active = False

    def set_stage(self, code: str) -> None:
        with self._lock:
            self._stage_code = code
            self._append_recent(code)

    def set_error(self, code: str) -> None:
        with self._lock:
            self._last_error_code = code
            self._append_recent(code)

    def set_connected_clients(self, count: int) -> None:
        with self._lock:
            self._connected_clients = count

    def set_runtime_active(self, active: bool) -> None:
        with self._lock:
            self._runtime_active = active

    def add_message(self, message: str) -> None:
        trimmed = " ".join(message.split())
        if not trimmed:
            return
        if len(trimmed) > 140:
            trimmed = trimmed[:137] + "..."
        with self._lock:
            if self._recent_messages and self._recent_messages[-1] == trimmed:
                return
            self._recent_messages.append(trimmed)

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return {
                "stage_code": self._stage_code,
                "last_error_code": self._last_error_code,
                "recent_codes": list(self._recent_codes),
                "recent_messages": list(self._recent_messages),
                "connected_clients": self._connected_clients,
                "runtime_active": self._runtime_active,
            }

    def clear_error(self) -> None:
        with self._lock:
            self._last_error_code = "NO"

    def _append_recent(self, code: str) -> None:
        if self._recent_codes and self._recent_codes[-1] == code:
            return
        self._recent_codes.append(code)


diagnostics_state = DiagnosticsState()
