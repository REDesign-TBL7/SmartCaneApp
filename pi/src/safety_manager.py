import time


class SafetyManager:
    def __init__(self, heartbeat_timeout_seconds: float = 1.5) -> None:
        self.heartbeat_timeout_seconds = heartbeat_timeout_seconds
        self.last_heartbeat_at = 0.0
        self.fault_code = "NONE"

    def register_heartbeat(self) -> None:
        self.last_heartbeat_at = time.monotonic()
        if self.fault_code == "HEARTBEAT_TIMEOUT":
            self.fault_code = "NONE"

    def has_heartbeat_timeout(self) -> bool:
        if self.last_heartbeat_at == 0.0:
            return True

        timed_out = (
            time.monotonic() - self.last_heartbeat_at
        ) > self.heartbeat_timeout_seconds
        if timed_out:
            self.fault_code = "HEARTBEAT_TIMEOUT"
        return timed_out

    def should_force_stop(self, nearest_obstacle_cm: float) -> bool:
        if self.has_heartbeat_timeout():
            return True

        if nearest_obstacle_cm >= 0 and nearest_obstacle_cm < 45:
            return True

        return False
