import asyncio
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import websockets

from camera_streamer import CameraStreamer
from comm_server import CommServer
from gps_manager import GPSManager
from imu_manager import HandleIMUManager
from motor_controller import MotorController
from network_manager import ensure_network, get_status, setup_ap
from safety_manager import SafetyManager

PID_FILE = Path("/run/smartcane-runtime.pid")
REPO_ROOT = Path(__file__).resolve().parents[2]
NETWORK_SCRIPT = REPO_ROOT / "infra" / "pi-network" / "smartcane_network.sh"
PI_DIR = Path(__file__).resolve().parents[1]
AP_TEST_RUNTIME_UNIT = "smartcane-ap-test-runtime"

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
    write_pid()
    
    if not ensure_network(do_install=False):
        logger.error("Network not ready. Run setup first: sudo infra/pi-network/setup.sh")
        remove_pid()
        sys.exit(1)
    
    comm_server = CommServer()
    motor_controller = MotorController()
    handle_imu_manager = HandleIMUManager()
    gps_manager = GPSManager()
    safety_manager = SafetyManager()
    camera_streamer = CameraStreamer()

    try:
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
        remove_pid()
        motor_controller.close()


def print_status() -> None:
    status = get_status()
    print("=== SmartCane Network Status ===")
    print(f"Interface: {status['interface']}")
    print(f"SSID: {status['ap_ssid']}")
    print(f"IP: {status['ap_ip']}")
    print(f"Root: {status['is_root']}")
    print(f"Packages: {'OK' if status['packages_installed'] else 'MISSING'}")
    print(f"Hostapd: {'active' if status['hostapd_active'] else 'inactive'}")
    print(f"Dnsmasq: {'active' if status['dnsmasq_active'] else 'inactive'}")
    print(f"IP Configured: {status['ip_configured']}")
    
    ready = all([
        status['packages_installed'],
        status['hostapd_active'],
        status['dnsmasq_active'],
        status['ip_configured'],
    ])
    print(f"\nStatus: {'READY' if ready else 'NOT READY'}")
    sys.exit(0 if ready else 1)


def network_ready() -> bool:
    status = get_status()
    return all(
        [
            status["packages_installed"],
            status["hostapd_active"],
            status["dnsmasq_active"],
            status["ip_configured"],
        ]
    )


def wait_for_network(timeout_seconds: int) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if network_ready():
            return True
        time.sleep(2)
    return network_ready()


def run_network_script(*args: str) -> int:
    command = [str(NETWORK_SCRIPT), *args]
    result = subprocess.run(command, check=False)
    return result.returncode


def runtime_service_installed() -> bool:
    result = subprocess.run(
        ["systemctl", "cat", "smartcane-runtime.service"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def arm_ap_test_runtime(wait_seconds: int) -> None:
    subprocess.run(
        ["systemctl", "stop", f"{AP_TEST_RUNTIME_UNIT}.service"],
        check=False,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ["systemctl", "reset-failed", f"{AP_TEST_RUNTIME_UNIT}.service"],
        check=False,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [
            "systemd-run",
            "--unit",
            AP_TEST_RUNTIME_UNIT,
            "--description",
            "SmartCane AP test runtime",
            "--property",
            f"WorkingDirectory={PI_DIR}",
            "--setenv",
            "PYTHONUNBUFFERED=1",
            sys.executable,
            str(Path(__file__).resolve()),
            "--wait-for-network",
            str(wait_seconds),
        ],
        check=True,
    )


def main() -> None:
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == "--setup":
            if os.geteuid() != 0:
                print("ERROR: --setup requires root. Run: sudo python src/main.py --setup")
                sys.exit(1)
            configure_logging()
            logger.info("Running AP setup...")
            success = setup_ap(do_install=True)
            sys.exit(0 if success else 1)
        elif arg == "--ap-test":
            if os.geteuid() != 0:
                print("ERROR: --ap-test requires root. Run: sudo python src/main.py --ap-test [seconds]")
                sys.exit(1)

            rollback_seconds = sys.argv[2] if len(sys.argv) > 2 else "300"
            if not runtime_service_installed():
                arm_ap_test_runtime(wait_seconds=90)
            sys.exit(run_network_script("ap-test", "--rollback", rollback_seconds))
        elif arg == "--confirm-ap-test":
            if os.geteuid() != 0:
                print("ERROR: --confirm-ap-test requires root. Run: sudo python src/main.py --confirm-ap-test")
                sys.exit(1)
            sys.exit(run_network_script("confirm-test"))
        elif arg == "--rollback-ap-test":
            if os.geteuid() != 0:
                print("ERROR: --rollback-ap-test requires root. Run: sudo python src/main.py --rollback-ap-test")
                sys.exit(1)
            sys.exit(run_network_script("rollback-now"))
        elif arg == "--wait-for-network":
            timeout_seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 60
            if not wait_for_network(timeout_seconds):
                print(f"ERROR: network not ready after waiting {timeout_seconds} seconds")
                sys.exit(1)
        elif arg == "--status":
            print_status()
        elif arg == "--help":
            print("Usage: python src/main.py [--setup|--ap-test [seconds]|--confirm-ap-test|--rollback-ap-test|--status|--help]")
            print("  No args: Start runtime (assumes network already configured)")
            print("  --setup: Configure AP mode (includes package install)")
            print("  --ap-test [seconds]: Switch to AP mode with timed rollback for headless testing")
            print("  --confirm-ap-test: Cancel the pending AP rollback and keep AP mode")
            print("  --rollback-ap-test: Restore the previous client Wi-Fi immediately")
            print("  --wait-for-network [seconds]: Wait for AP readiness, then start runtime")
            print("  --status: Print network status")
            sys.exit(0)
        else:
            print(f"Unknown argument: {arg}")
            print("Run: python src/main.py --help")
            sys.exit(1)
    
    asyncio.run(run_server())


if __name__ == "__main__":
    main()
