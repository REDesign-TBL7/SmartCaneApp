import base64
import io
import logging
import os
import pwd
import shutil
import subprocess
import time
import uuid
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
        self._last_init_attempt_monotonic = 0.0
        self._retry_interval_seconds = 1.0
        self._cli_capture_cmd = self._detect_cli_capture_cmd()
        self._cli_capture_run_as_pi = self._should_run_cli_as_pi()

        self._ensure_camera_ready(force=True)

    @staticmethod
    def _rotate_image_for_vision(image: Image.Image) -> Image.Image:
        # The physical Pi camera is mounted sideways relative to the phone UI.
        # Rotate once here so both the preview and VLM see the same upright frame.
        return image.rotate(-90, expand=True)

    def _encode_image_to_base64_jpeg(self, image: Image.Image) -> str:
        rotated = self._rotate_image_for_vision(image)
        if rotated.mode != "RGB":
            rotated = rotated.convert("RGB")
        buffer = io.BytesIO()
        rotated.save(
            buffer,
            format="JPEG",
            quality=self.jpeg_quality,
            optimize=False,
            subsampling=2,
        )
        return base64.b64encode(buffer.getvalue()).decode("ascii")

    @staticmethod
    def _should_run_cli_as_pi() -> bool:
        if os.geteuid() != 0:
            return False

        try:
            pwd.getpwnam("pi")
        except KeyError:
            return False

        return shutil.which("runuser") is not None

    def _detect_cli_capture_cmd(self) -> list[str] | None:
        rpicam_jpeg = shutil.which("rpicam-jpeg")
        if rpicam_jpeg is not None:
            command = [
                rpicam_jpeg,
                "--camera", "0",
                "--nopreview",
                "--timeout", "1",
                "--width", str(self.width),
                "--height", str(self.height),
                "--quality", str(self.jpeg_quality),
            ]
            if self._should_run_cli_as_pi():
                return ["runuser", "-u", "pi", "--"] + command
            return command

        rpicam_still = shutil.which("rpicam-still")
        if rpicam_still is not None:
            command = [
                rpicam_still,
                "--camera", "0",
                "--nopreview",
                "--timeout", "1",
                "--width", str(self.width),
                "--height", str(self.height),
                "--quality", str(self.jpeg_quality),
            ]
            if self._should_run_cli_as_pi():
                return ["runuser", "-u", "pi", "--"] + command
            return command

        return None

    def _ensure_camera_ready(self, force: bool = False) -> bool:
        if Picamera2 is None:
            self.available = False
            return False

        if self.picam is not None:
            self.available = True
            return True

        now = time.monotonic()
        if not force and now - self._last_init_attempt_monotonic < self._retry_interval_seconds:
            return False

        self._last_init_attempt_monotonic = now

        try:
            picam = Picamera2()
            config = picam.create_preview_configuration(
                main={"size": (self.width, self.height), "format": "RGB888"}
            )
            picam.configure(config)
            picam.start()
            self.picam = picam
            self.available = True
            logger.info("Camera stream initialized at %sx%s", self.width, self.height)
            return True
        except Exception as exc:
            logger.warning("Camera unavailable, will retry video stream startup: %s", exc)
            self.available = False
            self.picam = None
            return False

    @staticmethod
    def _normalize_frame_for_jpeg(frame: Any) -> Any:
        shape = getattr(frame, "shape", None)
        if not shape or len(shape) != 3 or shape[2] < 3:
            return frame

        # Picamera2 preview frames can arrive in BGR/XBGR order even when the
        # requested format is RGB-like. Swap into RGB before JPEG encoding.
        if shape[2] == 3:
            return frame[:, :, [2, 1, 0]]
        if shape[2] >= 4:
            return frame[:, :, [2, 1, 0, 3]]
        return frame

    def _capture_frame_via_cli(self) -> str | None:
        if self._cli_capture_cmd is None:
            return None

        temp_path = os.path.join("/tmp", f"smartcane-frame-{uuid.uuid4().hex}.jpg")
        try:
            result = subprocess.run(
                [*self._cli_capture_cmd, "--output", temp_path],
                check=False,
                capture_output=True,
                timeout=4,
            )
        except Exception as exc:
            logger.warning("CLI camera capture failed, will retry later: %s", exc)
            return None

        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="ignore").strip()
            stdout = result.stdout.decode("utf-8", errors="ignore").strip()
            logger.warning(
                "CLI camera capture failed rc=%s stderr=%s stdout=%s",
                result.returncode,
                stderr or "(empty)",
                stdout or "(empty)",
            )
            return None

        if not os.path.exists(temp_path):
            logger.warning("CLI camera capture returned no output file")
            return None

        try:
            frame_bytes = open(temp_path, "rb").read()
        except OSError as exc:
            logger.warning("CLI camera capture could not read %s: %s", temp_path, exc)
            return None
        finally:
            try:
                os.remove(temp_path)
            except OSError:
                logger.debug("Could not remove temporary camera frame %s", temp_path, exc_info=True)

        if not frame_bytes:
            logger.warning("CLI camera capture returned an empty JPEG")
            return None

        self.available = True
        logger.info("Camera CLI capture initialized at %sx%s", self.width, self.height)
        try:
            image = Image.open(io.BytesIO(frame_bytes))
            image.load()
        except Exception as exc:
            logger.warning("CLI camera capture returned unreadable JPEG: %s", exc)
            return None
        return self._encode_image_to_base64_jpeg(image)

    def next_frame_base64(self) -> str | None:
        if not self._ensure_camera_ready():
            return self._capture_frame_via_cli()

        try:
            frame = self.picam.capture_array()
        except Exception as exc:
            logger.warning("Camera frame capture failed, retrying video stream startup later: %s", exc)
            try:
                self.picam.stop()
            except Exception:
                logger.debug("Camera stop after capture failure raised", exc_info=True)
            self.available = False
            self.picam = None
            return None
        frame = self._normalize_frame_for_jpeg(frame)
        image = Image.fromarray(frame)
        return self._encode_image_to_base64_jpeg(image)

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
