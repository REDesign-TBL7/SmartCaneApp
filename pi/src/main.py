import asyncio

import websockets

from camera_streamer import CameraStreamer
from comm_server import CommServer
from gps_manager import GPSManager
from imu_manager import HandleIMUManager
from motor_controller import MotorController
from safety_manager import SafetyManager
from ultrasonic_manager import UltrasonicManager


async def telemetry_and_control_loop(
    comm_server: CommServer,
    motor_controller: MotorController,
    ultrasonic_manager: UltrasonicManager,
    handle_imu_manager: HandleIMUManager,
    gps_manager: GPSManager,
    safety_manager: SafetyManager,
) -> None:
    last_heartbeat_count = 0

    while True:
        obstacle_cm = ultrasonic_manager.read_nearest_obstacle_cm()
        handle_imu = handle_imu_manager.read_camera_deblur_sample()
        motor_imu = motor_controller.poll_motor_imu()

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
            motor_controller.stop()
        else:
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

        await asyncio.sleep(0.2)


async def camera_stream_loop(
    comm_server: CommServer, camera_streamer: CameraStreamer
) -> None:
    while True:
        packet = camera_streamer.frame_packet()
        if packet is not None:
            await comm_server.broadcast_telemetry(packet)
        await asyncio.sleep(0.45)


async def run_server() -> None:
    comm_server = CommServer()
    motor_controller = MotorController()
    ultrasonic_manager = UltrasonicManager()
    handle_imu_manager = HandleIMUManager()
    gps_manager = GPSManager()
    safety_manager = SafetyManager()
    camera_streamer = CameraStreamer()

    try:
        async with websockets.serve(comm_server.handler, "0.0.0.0", 8080):
            await asyncio.gather(
                telemetry_and_control_loop(
                    comm_server,
                    motor_controller,
                    ultrasonic_manager,
                    handle_imu_manager,
                    gps_manager,
                    safety_manager,
                ),
                camera_stream_loop(comm_server, camera_streamer),
            )
    finally:
        motor_controller.close()
        ultrasonic_manager.close()


if __name__ == "__main__":
    asyncio.run(run_server())
