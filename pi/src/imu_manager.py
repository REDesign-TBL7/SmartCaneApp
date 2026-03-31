import math
import time

try:
    import smbus2
except ImportError:  # pragma: no cover - for local dev
    smbus2 = None


class IMUManager:
    MPU9250_ADDR = 0x68
    REG_PWR_MGMT_1 = 0x6B
    REG_GYRO_ZOUT_H = 0x47

    def __init__(self, bus_id: int = 1) -> None:
        self.heading = 0.0
        self.last_ts = time.monotonic()
        self.gyro_z_bias = 0.0
        self.available = smbus2 is not None
        self.bus = smbus2.SMBus(bus_id) if self.available else None

        if self.available:
            self.bus.write_byte_data(self.MPU9250_ADDR, self.REG_PWR_MGMT_1, 0x00)
            time.sleep(0.1)
            self._calibrate_bias()

    def _read_word(self, reg: int) -> int:
        high = self.bus.read_byte_data(self.MPU9250_ADDR, reg)
        low = self.bus.read_byte_data(self.MPU9250_ADDR, reg + 1)
        value = (high << 8) | low
        if value >= 0x8000:
            value -= 0x10000
        return value

    def _calibrate_bias(self, samples: int = 120) -> None:
        if not self.available:
            return
        total = 0.0
        for _ in range(samples):
            total += self._read_word(self.REG_GYRO_ZOUT_H)
            time.sleep(0.005)
        self.gyro_z_bias = total / samples

    def read_heading_degrees(self) -> float:
        now = time.monotonic()
        dt = max(0.001, now - self.last_ts)
        self.last_ts = now

        if not self.available:
            self.heading = (self.heading + 0.0) % 360
            return self.heading

        raw_z = self._read_word(self.REG_GYRO_ZOUT_H)
        dps = (raw_z - self.gyro_z_bias) / 131.0
        self.heading = (self.heading + dps * dt) % 360
        if math.isnan(self.heading):
            self.heading = 0.0
        return self.heading
