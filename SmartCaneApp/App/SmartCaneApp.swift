/*
 File: SmartCaneApp.swift
 Purpose:
 This is the SwiftUI app entry point.
 It creates the shared managers once and injects them into the view hierarchy.
*/

import SwiftUI

@main
struct SmartCaneDemoApp: App {
    /// Managers are created once here and shared through the entire app.
    @StateObject private var connectionManager: CaneConnectionManager
    @StateObject private var locationManager: LocationManager
    @StateObject private var speechManager: SpeechManager
    @StateObject private var profileManager: ProfileManager

    init() {
        let profileManager = ProfileManager()
        let connectionManager = CaneConnectionManager()
        _profileManager = StateObject(wrappedValue: profileManager)
        _connectionManager = StateObject(wrappedValue: connectionManager)
        _locationManager = StateObject(wrappedValue: LocationManager(profileManager: profileManager, connectionManager: connectionManager))
        _speechManager = StateObject(wrappedValue: SpeechManager())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(connectionManager)
                .environmentObject(locationManager)
                .environmentObject(speechManager)
                .environmentObject(profileManager)
                .tint(Color(red: 0.18, green: 0.34, blue: 0.37))
        }
    }
}
