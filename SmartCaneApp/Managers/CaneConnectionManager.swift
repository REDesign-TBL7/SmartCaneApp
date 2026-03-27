/*
 File: CaneConnectionManager.swift
 Purpose:
 This file manages the app's current connection to the smart cane.

 Status:
 The app is now planned around Wi-Fi communication with the Raspberry Pi Zero.
 The methods below still run in demo mode so the UI can be tested before the
 real network transport is implemented.
*/

import Foundation

@MainActor
final class CaneConnectionManager: ObservableObject {
    /// The shared state that SwiftUI reads to update the screen.
    @Published var caneState = CaneState()
    private let demoHost = "192.168.1.50"
    private let demoPort = "8080"

    init() {
        // This gives the UI useful sample data until the real Wi-Fi transport is ready.
        caneState.connectionStatus = .disconnected
        caneState.batteryPercentage = 100
        caneState.currentInstruction = "No active navigation"
        caneState.currentNavigationCommand = .stop
        caneState.obstacleMessage = "No obstacles detected"
        caneState.statusMessage = "Waiting for Wi-Fi endpoint details from the Raspberry Pi"
    }

    /// This will later open the real Wi-Fi connection to the Raspberry Pi.
    func connectToCane() {
        caneState.connectionStatus = .connecting
        caneState.statusMessage = "Demo mode: connecting over Wi-Fi to \(demoHost):\(demoPort)"
    }

    /// Call this when the user wants to stop talking to the cane.
    func disconnectFromCane() {
        caneState.connectionStatus = .disconnected
        caneState.currentNavigationCommand = .stop
        caneState.statusMessage = "Demo mode: Wi-Fi connection closed"
    }

    /// This lets the demo UI mark the cane as connected without needing live hardware yet.
    func markConnectedForDemo() {
        caneState.connectionStatus = .connected
        caneState.statusMessage = "Connected to cane over Wi-Fi"
    }

    /// Accepts a simplified direction command that can later be written to the Pi Zero.
    func sendNavigationCommand(_ command: NavigationCommand, instructionText: String) {
        caneState.currentNavigationCommand = command
        caneState.currentInstruction = instructionText

        // TODO: Replace this demo state update with a real Wi-Fi send.
        // A practical choice here is URLSessionWebSocketTask with a tiny JSON payload:
        // { "command": "LEFT" } / { "command": "RIGHT" } / { "command": "FORWARD" }
        caneState.statusMessage = "Queued Wi-Fi direction: \(command.rawValue)"
    }
}
