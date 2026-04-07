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
    @StateObject private var visionManager: VisionManager
    @StateObject private var fusionManager: GuidanceFusionManager

    init() {
        let profileManager = ProfileManager()
        let connectionManager = CaneConnectionManager()
        let visionManager = VisionManager(connectionManager: connectionManager)
        let fusionManager = GuidanceFusionManager(connectionManager: connectionManager, visionManager: visionManager)
#if canImport(FastVLM) && canImport(MLXVLM)
        visionManager.fastVLMEngine = FastVLMAppleEngine()
#endif
        _profileManager = StateObject(wrappedValue: profileManager)
        _connectionManager = StateObject(wrappedValue: connectionManager)
        _locationManager = StateObject(wrappedValue: LocationManager(profileManager: profileManager, connectionManager: connectionManager, fusionManager: fusionManager))
        _speechManager = StateObject(wrappedValue: SpeechManager())
        _visionManager = StateObject(wrappedValue: visionManager)
        _fusionManager = StateObject(wrappedValue: fusionManager)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(connectionManager)
                .environmentObject(locationManager)
                .environmentObject(speechManager)
                .environmentObject(profileManager)
                .environmentObject(visionManager)
                .environmentObject(fusionManager)
                .tint(Color(red: 0.18, green: 0.34, blue: 0.37))
        }
    }
}
