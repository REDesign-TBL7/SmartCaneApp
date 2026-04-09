/*
 File: CaneState.swift
 Purpose:
 This file defines the shared app state for the smart cane.

 Why this exists:
 SwiftUI views update automatically when @Published values change.
 By keeping the important cane data in one model, the UI can react to:
 - connection changes
 - obstacle alerts
 - navigation instruction changes

 This model is intentionally simple so it is easy to understand and expand later.
*/

import Foundation

/// A simple enum that describes the cane connection state in human-readable form.
enum CaneConnectionStatus: String, Codable {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
}

/// High-level navigation directions sent to the cane.
enum NavigationCommand: String, Codable {
    case left = "LEFT"
    case right = "RIGHT"
    case forward = "FORWARD"
    case stop = "STOP"
}

enum GPSFixStatus: String, Codable {
    case noFix = "NO_FIX"
    case fix2D = "FIX_2D"
    case fix3D = "FIX_3D"
}

enum CaneFaultCode: String, Codable {
    case none = "NONE"
    case imuUnavailable = "IMU_UNAVAILABLE"
    case handleIMUUnavailable = "HANDLE_IMU_UNAVAILABLE"
    case motorIMUUnavailable = "MOTOR_IMU_UNAVAILABLE"
    case gpsUnavailable = "GPS_UNAVAILABLE"
    case motorDriverFault = "MOTOR_DRIVER_FAULT"
    case ultrasonicFault = "ULTRASONIC_FAULT"
    case heartbeatTimeout = "HEARTBEAT_TIMEOUT"
}

enum CaneNetworkMode: String, Codable {
    case auto = "AUTO"
    case piAccessPoint = "PI_AP"
    case phoneHotspot = "PHONE_HOTSPOT"
}

/// A shared model describing the latest known state of the cane.
struct CaneState: Codable {
    /// The most recent connection state.
    var connectionStatus: CaneConnectionStatus = .disconnected

    /// A short text message describing the latest obstacle event.
    var obstacleMessage: String = "No obstacles detected"

    /// The latest navigation instruction that should be shown and spoken.
    var currentInstruction: String = "No active navigation"

    /// The latest simplified direction command for the cane motors.
    var currentNavigationCommand: NavigationCommand = .stop

    /// Extra status text that can be shown on screen for debugging or user feedback.
    var statusMessage: String = "Waiting for cane"

    /// Nearest obstacle distance reported by Pi sensors.
    var nearestObstacleCm: Double = -1

    /// Current motor/tip-unit heading in degrees from the ESP32 IMU.
    /// This should be used for haptic motor guidance decisions.
    var motorUnitHeadingDegrees: Double = 0

    /// True when the ESP32 reports valid motor-unit IMU data.
    var isMotorUnitIMUAvailable = false

    /// Handle-mounted Pi IMU data reserved for camera deblur/stabilization.
    var isHandleIMUAvailable = false
    var handleIMUHeadingDegrees: Double = 0
    var handleIMUGyroZDegreesPerSecond: Double = 0

    /// GPS fix quality from Pi GPS module.
    var gpsFixStatus: GPSFixStatus = .noFix

    /// Last received VLM scene summary from on-device FastVLM.
    var vlmSummary: String = "VLM idle"

    /// Last protocol timestamp from telemetry.
    var lastTelemetryTimestampMs: Int64 = 0

    /// Latest cane fault code.
    var faultCode: CaneFaultCode = .none

    /// Selected local transport profile for the cane link.
    var networkMode: CaneNetworkMode = .auto
}

struct OutboundCaneMessage: Codable {
    let type: String
    let protocolVersion: Int
    let timestampMs: Int64
    let command: NavigationCommand?
    let instructionText: String?
    let heartbeat: Bool?
    let vlmSummary: String?
    let latitude: Double?
    let longitude: Double?

    static func command(_ command: NavigationCommand, instructionText: String) -> OutboundCaneMessage {
        OutboundCaneMessage(
            type: "DISCRETE_CMD",
            protocolVersion: 1,
            timestampMs: Self.nowMs,
            command: command,
            instructionText: instructionText,
            heartbeat: nil,
            vlmSummary: nil,
            latitude: nil,
            longitude: nil
        )
    }

    static func heartbeat(vlmSummary: String?, latitude: Double?, longitude: Double?) -> OutboundCaneMessage {
        OutboundCaneMessage(
            type: "HEARTBEAT",
            protocolVersion: 1,
            timestampMs: Self.nowMs,
            command: nil,
            instructionText: nil,
            heartbeat: true,
            vlmSummary: vlmSummary,
            latitude: latitude,
            longitude: longitude
        )
    }

    private static var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

struct InboundTelemetryMessage: Codable {
    let type: String
    let obstacleDistanceCm: Double?
    let motorImuAvailable: Bool?
    let motorImuHeadingDegrees: Double?
    let motorImuPitchDegrees: Double?
    let motorImuRollDegrees: Double?
    let handleImuAvailable: Bool?
    let handleImuHeadingDegrees: Double?
    let handleImuGyroZDegreesPerSecond: Double?
    /// Legacy heading field kept for older Pi telemetry. New data should use
    /// motorImuHeadingDegrees instead.
    let headingDegrees: Double?
    let gpsFixStatus: GPSFixStatus?
    let statusMessage: String?
    let faultCode: CaneFaultCode?
    let timestampMs: Int64?
}

struct InboundFrameMessage: Codable {
    let type: String
    let timestampMs: Int64?
    let jpegBase64: String?
}
