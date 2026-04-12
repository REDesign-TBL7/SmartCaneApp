import asyncio
import logging
import os
import signal
import sys
import time
from pathlib import Path

import websockets

from ble_diagnostics import BluetoothDiagnosticsBeacon
from ble_provisioning import BluetoothProvisioningService
from camera_streamer import CameraStreamer
from comm_server import CommServer
from diagnostics_state import diagnostics_state
from gps_manager import GPSManager
from imu_manager import HandleIMUManager
from motor_controller import MotorController
from network_manager import ensure_network, get_status, setup_hotspot_client, store_hotspot_credentials
from safety_manager import SafetyManager

PID_FILE = Path("/run/smartcane-runtime.pid")


def write_pid() -> None:
    PID_FILE.write_text(str(os.getpid()))

def remove_pid() -> None:
    PID_FILE.unlink(missing_ok=True)


def configure_logging() -> None:
    os.makedirs("logs", exist_ok=True)
    log_level_name = os.getenv("SMARTCANE_LOG_LEVEL", "INFO").upper()
    log_level = getattr(logging, log_level_name, logging.INFO)
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
    comm_server: CommServer,
    camera_streamer: CameraStreamer,
    handle_imu_manager: HandleIMUManager,
) -> None:
    while True:
        handle_imu = handle_imu_manager.read_camera_deblur_sample()
        packet = camera_streamer.frame_packet(handle_imu)
        if packet is not None:
            await comm_server.broadcast_telemetry(packet)
            logger.debug(
                "Broadcasted camera frame packet with handle IMU available=%s gyroZ=%.2f",
                bool(handle_imu["available"]),
                float(handle_imu["gyro_z_dps"]),
            )
        await asyncio.sleep(0.45)


async def bluetooth_diagnostics_loop(
    beacon: BluetoothDiagnosticsBeacon,
    connected_clients_provider,
    fault_code_provider,
) -> None:
    await asyncio.to_thread(beacon.publish, True)
    while True:
        beacon.update_runtime_state(
            fault_code=fault_code_provider(),
            connected_clients=connected_clients_provider(),
            runtime_active=bool(diagnostics_state.snapshot()["runtime_active"]),
        )
        await asyncio.to_thread(beacon.publish, False)
        await asyncio.sleep(4)


async def apply_ble_hotspot_credentials(ssid: str, password: str) -> bool:
    logger.info("Applying hotspot credentials received over BLE for SSID=%s", ssid)
    diagnostics_state.add_message(f"Applying BLE hotspot credentials for {ssid}")
    store_hotspot_credentials(ssid, password, source="BLE")
    diagnostics_state.set_stage("PJ")
    success = await asyncio.to_thread(setup_hotspot_client, False)
    if success:
        diagnostics_state.clear_error()
        diagnostics_state.set_stage("NR")
        return True

    diagnostics_state.set_error("HC")
    return False


def provisioning_status_snapshot() -> dict[str, object]:
    snapshot = diagnostics_state.snapshot()
    status = get_status()
    return {
        **snapshot,
        **status,
    }


async def wait_for_network_ready() -> None:
    while True:
        connected = await asyncio.to_thread(ensure_network, False)
        if connected:
            diagnostics_state.clear_error()
            diagnostics_state.set_stage("NR")
            diagnostics_state.add_message("Network marked ready")
            return

        status = get_status()
        snapshot = diagnostics_state.snapshot()
        if status["hotspot_ssid"]:
            diagnostics_state.set_stage("PJ")
            if snapshot["last_error_code"] == "NO":
                diagnostics_state.clear_error()
            diagnostics_state.add_message(
                f"Waiting for Wi-Fi join on {status['last_attempted_ssid'] or status['hotspot_ssid']}"
            )
        else:
            diagnostics_state.set_stage("PV")
            if snapshot["last_error_code"] == "NO":
                diagnostics_state.set_error("NF")
            diagnostics_state.add_message("Waiting for hotspot credentials over BLE or boot config")
        await asyncio.sleep(3)


async def run_server() -> None:
    configure_logging()
    logger.info("Starting SmartCane Pi runtime")
    diagnostics_state.set_runtime_active(True)
    diagnostics_state.set_stage("BO")
    diagnostics_state.add_message("Runtime booting")
    write_pid()
    ble_beacon = BluetoothDiagnosticsBeacon()
    provisioning_service = BluetoothProvisioningService(
        apply_credentials=apply_ble_hotspot_credentials,
        status_provider=provisioning_status_snapshot,
    )
    diagnostics_task: asyncio.Task[None] | None = None
    provisioning_started = await provisioning_service.start()
    if not provisioning_started:
        diagnostics_task = asyncio.create_task(
            bluetooth_diagnostics_loop(
                ble_beacon,
                connected_clients_provider=lambda: 0,
                fault_code_provider=lambda: "NONE",
            )
        )

    try:
        if not network_ready():
            logger.info("Network not ready; staying in BLE provisioning mode until hotspot credentials work")
            diagnostics_state.add_message("Network not ready; BLE provisioning mode active")
            await wait_for_network_ready()

        comm_server = CommServer()
        motor_controller = MotorController()
        handle_imu_manager = HandleIMUManager()
        if handle_imu_manager.available:
            diagnostics_state.add_message(
                f"Handle IMU ready on I2C bus {handle_imu_manager.bus_id} addr {hex(handle_imu_manager.device_address)}"
            )
        else:
            diagnostics_state.add_message(
                f"Handle IMU unavailable on I2C bus {handle_imu_manager.bus_id}: {handle_imu_manager.error_message or 'unknown error'}"
            )
        gps_manager = GPSManager()
        safety_manager = SafetyManager()
        camera_streamer = CameraStreamer()
        if diagnostics_task is not None:
            diagnostics_task.cancel()
            await asyncio.gather(diagnostics_task, return_exceptions=True)
            diagnostics_task = asyncio.create_task(
                bluetooth_diagnostics_loop(
                    ble_beacon,
                    connected_clients_provider=lambda: len(comm_server.clients),
                    fault_code_provider=lambda: safety_manager.fault_code,
                )
            )

        async with websockets.serve(comm_server.handler, "0.0.0.0", 8080):
            logger.info("WebSocket server listening on 0.0.0.0:8080")
            diagnostics_state.set_stage("WL")
            diagnostics_state.add_message("WebSocket server listening on port 8080")
            tasks = [
                telemetry_and_control_loop(
                    comm_server,
                    motor_controller,
                    handle_imu_manager,
                    gps_manager,
                    safety_manager,
                ),
                camera_stream_loop(comm_server, camera_streamer, handle_imu_manager),
            ]
            if diagnostics_task is not None:
                tasks.append(diagnostics_task)
            await asyncio.gather(*tasks)
    finally:
        logger.info("Shutting down SmartCane Pi runtime")
        diagnostics_state.set_runtime_active(False)
        diagnostics_state.set_stage("SD")
        diagnostics_state.add_message("Runtime shutting down")
        if diagnostics_task is not None:
            diagnostics_task.cancel()
            await asyncio.gather(diagnostics_task, return_exceptions=True)
        await provisioning_service.stop()
        if diagnostics_task is not None:
            ble_beacon.update_runtime_state(fault_code="NONE", connected_clients=0, runtime_active=False)
            try:
                await asyncio.to_thread(ble_beacon.stop)
            except Exception:
                logger.debug("BLE diagnostics beacon stop failed", exc_info=True)
        remove_pid()
        if "motor_controller" in locals():
            motor_controller.close()


def print_status() -> None:
    status = get_status()
    print("=== SmartCane Network Status ===")
    print(f"Interface: {status['interface']}")
    print(f"Mode: {status['mode']}")
    print(f"Hotspot SSID: {status['hotspot_ssid'] or '(not configured)'}")
    print(f"Fallback SSID: {status['fallback_hotspot_ssid'] or '(not configured)'}")
    print(f"Configured Networks: {', '.join(status['configured_networks']) or '(none)'}")
    print(f"Connected SSID: {status['connected_ssid'] or '(not associated)'}")
    print(f"IP: {status['runtime_ip'] or '(not assigned)'}")
    print(f"Root: {status['is_root']}")
    print(f"Packages: {'OK' if status['packages_installed'] else 'MISSING'}")
    if status["missing_packages"]:
        print(f"Missing Packages: {', '.join(status['missing_packages'])}")
    print(f"NetworkManager: {'connected' if status['nm_active'] else 'not connected'}")
    print(f"Hotspot Client: {'active' if status['client_active'] else 'inactive'}")
    print(f"Last Connected SSID: {status['last_connected_ssid'] or '(none)'}")
    print(f"Last Attempted SSID: {status['last_attempted_ssid'] or '(none)'}")
    print(f"Last Failure: {status['last_failure_reason'] or '(none)'}")

    ready = all([
        status['client_active'],
        bool(status['runtime_ip']),
    ])
    print(f"\nStatus: {'READY' if ready else 'NOT READY'}")
    sys.exit(0 if ready else 1)


def network_ready() -> bool:
    status = get_status()
    return all(
        [
            status["client_active"],
            bool(status["runtime_ip"]),
        ]
    )


def wait_for_network(timeout_seconds: int) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if network_ready():
            return True
        time.sleep(2)
    return network_ready()


def main() -> None:
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg in ("--setup", "--setup-hotspot"):
            if os.geteuid() != 0:
                print(f"ERROR: {arg} requires root. Run: sudo python src/main.py {arg}")
                sys.exit(1)
            configure_logging()
            logger.info("Running hotspot client setup...")
            success = setup_hotspot_client(do_install=True)
            sys.exit(0 if success else 1)
        elif arg == "--wait-for-network":
            timeout_seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 60
            if not wait_for_network(timeout_seconds):
                print(f"ERROR: network not ready after waiting {timeout_seconds} seconds")
                sys.exit(1)
        elif arg == "--status":
            print_status()
        elif arg == "--help":
            print("Usage: python src/main.py [--setup|--setup-hotspot|--wait-for-network [seconds]|--status|--help]")
            print("  No args:               Start runtime (auto-imports hotspot credentials from /boot if available)")
            print("  --setup:               Configure hotspot client (includes package install)")
            print("  --setup-hotspot:       Alias for --setup")
            print("  --wait-for-network N:  Wait up to N seconds for hotspot-client readiness")
            print("  --status:              Print network status and exit")
            sys.exit(0)
        else:
            print(f"Unknown argument: {arg}")
            print("Run: python src/main.py --help")
            sys.exit(1)

    asyncio.run(run_server())


if __name__ == "__main__":
    main()
