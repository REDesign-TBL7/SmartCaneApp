import math
import time

try:
    import smbus2
except ImportError:  # pragma: no cover - for local dev
    smbus2 = None


class HandleIMUManager:
    """IMU on the cane handle, used for camera-frame stabilization/deblur.

    The motor-control IMU is no longer read by the Raspberry Pi. That IMU lives
    on the ESP32 motor unit and is reported back over the Pi-to-ESP32 serial
    bridge.
    """

    MPU9250_ADDR = 0x68
    REG_PWR_MGMT_1 = 0x6B
    REG_GYRO_ZOUT_H = 0x47

    def __init__(self, bus_id: int = 1) -> None:
        self.heading = 0.0
        self.last_gyro_z_dps = 0.0
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

    def read_camera_deblur_sample(self) -> dict[str, float | bool]:
        """Return handle IMU values for future camera deblur.

        TODO: Add gyro X/Y and accelerometer fields when the handle IMU driver is
        finalized. For now, we expose Z gyro integration because this was the
        existing MPU9250 signal already used by the Pi.
        """
        now = time.monotonic()
        dt = max(0.001, now - self.last_ts)
        self.last_ts = now

        if not self.available:
            self.heading = (self.heading + 0.0) % 360
            self.last_gyro_z_dps = 0.0
            return {
                "available": False,
                "heading_degrees": self.heading,
                "gyro_z_dps": self.last_gyro_z_dps,
            }

        raw_z = self._read_word(self.REG_GYRO_ZOUT_H)
        dps = (raw_z - self.gyro_z_bias) / 131.0
        self.last_gyro_z_dps = dps
        self.heading = (self.heading + dps * dt) % 360
        if math.isnan(self.heading):
            self.heading = 0.0
        return {
            "available": True,
            "heading_degrees": self.heading,
            "gyro_z_dps": self.last_gyro_z_dps,
        }


# Backward-compatible alias for older imports.
IMUManager = HandleIMUManager
