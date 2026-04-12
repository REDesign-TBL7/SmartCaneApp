import logging
import math
import os
import time

try:
    import smbus2
except ImportError:  # pragma: no cover - for local dev
    smbus2 = None


logger = logging.getLogger(__name__)


class HandleIMUManager:
    """IMU on the cane handle, used for camera-frame stabilization/deblur.

    The motor-control IMU is no longer read by the Raspberry Pi. That IMU lives
    on the ESP32 motor unit and is reported back over the Pi-to-ESP32 serial
    bridge.
    """

    MPU6050_ADDR = 0x68
    REG_PWR_MGMT_1 = 0x6B
    REG_GYRO_ZOUT_H = 0x47

    def __init__(self, bus_id: int = 1) -> None:
        self.heading = 0.0
        self.last_gyro_z_dps = 0.0
        self.last_ts = time.monotonic()
        self.gyro_z_bias = 0.0
        self.error_message = ""
        self.bus_id = int(os.getenv("SMARTCANE_HANDLE_IMU_BUS", str(bus_id)))
        self.device_address = int(
            os.getenv("SMARTCANE_HANDLE_IMU_ADDR", str(self.MPU6050_ADDR)),
            0,
        )
        self.available = smbus2 is not None
        self.bus = None

        if not self.available:
            self.error_message = "smbus2 unavailable"
            logger.warning("Handle IMU disabled: smbus2 is not installed")
            return

        try:
            self.bus = smbus2.SMBus(self.bus_id)
            # MPU6050 and MPU9250 both use this register to exit sleep mode.
            self.bus.write_byte_data(self.device_address, self.REG_PWR_MGMT_1, 0x00)
            time.sleep(0.1)
            self._calibrate_bias()
            logger.info(
                "Handle IMU ready on I2C bus=%s addr=%s",
                self.bus_id,
                hex(self.device_address),
            )
        except OSError as exc:
            self.available = False
            self.bus = None
            self.error_message = str(exc)
            logger.warning(
                "Handle IMU unavailable on I2C bus=%s addr=%s: %s",
                self.bus_id,
                hex(self.device_address),
                exc,
            )

    @property
    def diagnostics(self) -> dict[str, str | int | bool]:
        return {
            "available": self.available,
            "bus": self.bus_id,
            "address": hex(self.device_address),
            "error": self.error_message,
        }

    def _read_word(self, reg: int) -> int:
        high = self.bus.read_byte_data(self.device_address, reg)
        low = self.bus.read_byte_data(self.device_address, reg + 1)
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
        finalized. For now, we expose Z gyro integration because this is the
        lowest-friction signal needed from the handle MPU6050 backup path.
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

        try:
            raw_z = self._read_word(self.REG_GYRO_ZOUT_H)
        except OSError as exc:
            self.available = False
            self.bus = None
            self.error_message = str(exc)
            logger.warning("Handle IMU read failed, disabling backup IMU: %s", exc)
            self.last_gyro_z_dps = 0.0
            return {
                "available": False,
                "heading_degrees": self.heading,
                "gyro_z_dps": self.last_gyro_z_dps,
            }

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
