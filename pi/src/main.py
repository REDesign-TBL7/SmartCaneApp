import asyncio
import logging
import os

import websockets

from camera_streamer import CameraStreamer
from comm_server import CommServer
from gps_manager import GPSManager
from imu_manager import HandleIMUManager
from mdns_advertiser import MDNSAdvertiser
from motor_controller import MotorController
from safety_manager import SafetyManager
from setup_server import start_setup_server


def configure_logging() -> None:
    os.makedirs("logs", exist_ok=True)
    log_level_name = os.getenv("SMARTCANE_LOG_LEVEL", "DEBUG").upper()
    log_level = getattr(logging, log_level_name, logging.DEBUG)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)
    root_logger.handlers.clear()

    console_handler = logging.StreamHandler()
    console_handler.setLevel(log_level)
    console_handler.setFormatter(formatter)

    file_handler = logging.FileHandler("logs/pi_runtime.log")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)

    root_logger.addHandler(console_handler)
    root_logger.addHandler(file_handler)


logger = logging.getLogger(__name__)


async def telemetry_and_control_loop(
    comm_server: CommServer,
    motor_controller: MotorController,
    handle_imu_manager: HandleIMUManager,
    gps_manager: GPSManager,
    safety_manager: SafetyManager,
) -> None:
    last_heartbeat_count = 0

    while True:
        motor_imu = motor_controller.poll_motor_imu()
        obstacle_cm = motor_controller.latest_ultrasonic.nearest_obstacle_cm
        handle_imu = handle_imu_manager.read_camera_deblur_sample()

        if comm_server.heartbeat_count > last_heartbeat_count:
            safety_manager.register_heartbeat()
            lat, lon = comm_server.latest_phone_location
            gps_manager.update_from_phone(lat, lon)
            last_heartbeat_count = comm_server.heartbeat_count

        gps = gps_manager.read()

        if obstacle_cm < 0:
            safety_manager.fault_code = "ULTRASONIC_FAULT"
        elif safety_manager.fault_code == "ULTRASONIC_FAULT":
            safety_manager.fault_code = "NONE"

        if safety_manager.should_force_stop(obstacle_cm):
            logger.debug("Safety forcing STOP, obstacle=%.2f fault=%s", obstacle_cm, safety_manager.fault_code)
            motor_controller.stop()
        else:
            logger.debug(
                "Applying app command=%s obstacle=%.2f heartbeat=%s",
                comm_server.latest_discrete_command,
                obstacle_cm,
                comm_server.heartbeat_count,
            )
            motor_controller.apply_discrete_command(comm_server.latest_discrete_command)

        telemetry = comm_server.telemetry_payload(
            obstacle_distance_cm=obstacle_cm,
            motor_imu_available=motor_imu.available,
            motor_imu_heading_degrees=motor_imu.heading_degrees,
            motor_imu_pitch_degrees=motor_imu.pitch_degrees,
            motor_imu_roll_degrees=motor_imu.roll_degrees,
            handle_imu_available=bool(handle_imu["available"]),
            handle_imu_heading_degrees=float(handle_imu["heading_degrees"]),
            handle_imu_gyro_z_dps=float(handle_imu["gyro_z_dps"]),
            gps_fix_status=gps.fix_status,
            fault_code=safety_manager.fault_code,
            status_message=motor_controller.status_message,
        )
        await comm_server.broadcast_telemetry(telemetry)
        logger.debug(
            "Telemetry sent obstacle=%.2f motor_heading=%s handle_heading=%.2f gps=%s fault=%s",
            obstacle_cm,
            motor_imu.heading_degrees,
            float(handle_imu["heading_degrees"]),
            gps.fix_status,
            safety_manager.fault_code,
        )

        await asyncio.sleep(0.2)


async def camera_stream_loop(
    comm_server: CommServer, camera_streamer: CameraStreamer
) -> None:
    while True:
        packet = camera_streamer.frame_packet()
        if packet is not None:
            await comm_server.broadcast_telemetry(packet)
            logger.debug("Broadcasted camera frame packet")
        await asyncio.sleep(0.45)


async def run_server() -> None:
    configure_logging()
    logger.info("Starting SmartCane Pi runtime")
    comm_server = CommServer()
    motor_controller = MotorController()
    handle_imu_manager = HandleIMUManager()
    gps_manager = GPSManager()
    safety_manager = SafetyManager()
    camera_streamer = CameraStreamer()
    setup_server, _ = start_setup_server()
    mdns_advertiser = MDNSAdvertiser(
        device_name=comm_server.device_name,
        device_id=comm_server.device_id,
        port=8080,
    )

    try:
        mdns_advertiser.start()
        async with websockets.serve(comm_server.handler, "0.0.0.0", 8080):
            logger.info("WebSocket server listening on 0.0.0.0:8080")
            await asyncio.gather(
                telemetry_and_control_loop(
                    comm_server,
                    motor_controller,
                    handle_imu_manager,
                    gps_manager,
                    safety_manager,
                ),
                camera_stream_loop(comm_server, camera_streamer),
            )
    finally:
        logger.info("Shutting down SmartCane Pi runtime")
        mdns_advertiser.stop()
        setup_server.shutdown()
        setup_server.server_close()
        motor_controller.close()


if __name__ == "__main__":
    asyncio.run(run_server())
