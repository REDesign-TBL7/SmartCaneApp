/*
 File: CaneState.swift
 Purpose:
 This file defines the shared app state for the smart cane.

 Why this exists:
 SwiftUI views update automatically when @Published values change.
 By keeping the important cane data in one model, the UI can react to:
 - connection changes
 - battery level updates
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

/// A shared model describing the latest known state of the cane.
struct CaneState: Codable {
    /// The most recent connection state.
    var connectionStatus: CaneConnectionStatus = .disconnected

    /// Battery level from the Raspberry Pi, expected to be 0...100.
    var batteryPercentage: Int = 100

    /// A short text message describing the latest obstacle event.
    var obstacleMessage: String = "No obstacles detected"

    /// The latest navigation instruction that should be shown and spoken.
    var currentInstruction: String = "No active navigation"

    /// The latest simplified direction command for the cane motors.
    var currentNavigationCommand: NavigationCommand = .stop

    /// Extra status text that can be shown on screen for debugging or user feedback.
    var statusMessage: String = "Waiting for cane"
}
