import base64
import io
import logging
import time
from typing import Any

try:
    from picamera2 import Picamera2
except ImportError:  # pragma: no cover - for non-pi dev
    Picamera2 = None

from PIL import Image

logger = logging.getLogger(__name__)


class CameraStreamer:
    def __init__(
        self, width: int = 480, height: int = 270, jpeg_quality: int = 42
    ) -> None:
        self.width = width
        self.height = height
        self.jpeg_quality = jpeg_quality
        self.available = Picamera2 is not None
        self.picam = None

        if self.available:
            try:
                self.picam = Picamera2()
                config = self.picam.create_preview_configuration(
                    main={"size": (width, height), "format": "RGB888"}
                )
                self.picam.configure(config)
                self.picam.start()
            except Exception as exc:
                logger.warning("Camera unavailable, continuing without video stream: %s", exc)
                self.available = False
                self.picam = None

    def next_frame_base64(self) -> str | None:
        if not self.available:
            return None

        try:
            frame = self.picam.capture_array()
        except Exception as exc:
            logger.warning("Camera frame capture failed, disabling video stream: %s", exc)
            self.available = False
            self.picam = None
            return None
        image = Image.fromarray(frame)
        if image.mode != "RGB":
            image = image.convert("RGB")
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=self.jpeg_quality, optimize=False, subsampling=2)
        return base64.b64encode(buffer.getvalue()).decode("ascii")

    def frame_packet(self, handle_imu_sample: dict[str, Any] | None = None) -> dict[str, object] | None:
        encoded = self.next_frame_base64()
        if encoded is None:
            return None
        packet: dict[str, object] = {
            "type": "CAMERA_FRAME",
            "protocolVersion": 1,
            "timestampMs": int(time.time() * 1000),
            "jpegBase64": encoded,
        }
        if handle_imu_sample is not None:
            packet["handleImuAvailable"] = bool(handle_imu_sample.get("available", False))
            packet["handleImuHeadingDegrees"] = float(handle_imu_sample.get("heading_degrees", 0.0))
            packet["handleImuGyroZDegreesPerSecond"] = float(handle_imu_sample.get("gyro_z_dps", 0.0))
        return packet
