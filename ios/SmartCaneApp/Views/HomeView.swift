/*
 File: HomeView.swift
 Purpose:
 This file is the main blind-first app screen.

 Layout:
 1. Cane connection
 2. Current destination
 3. Live FastVLM scene output
*/

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var visionManager: VisionManager
    @State private var showsNavigationSearch = false

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        navigationSection
                        vlmSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 92)
                }

                VStack {
                    Spacer()
                    HStack {
                        readMenuButton
                        Spacer()
                        VoiceCommandButton()
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("Smart Cane")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsNavigationSearch) {
                NavigationView()
            }
            .onAppear {
                speechManager.speak("Smart Cane ready. Use Read for status, or Speak for voice commands.")
            }
            .onChange(of: connectionManager.caneState.connectionStatus) { newStatus in
                speechManager.speakUrgent("Cane connection \(newStatus.rawValue.lowercased()).")
                visionManager.setInferenceEnabled(newStatus == .connected)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: UserProfileView()) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: 44, height: 44)

                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(Color(red: 0.19, green: 0.28, blue: 0.32))
                        }
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.7), lineWidth: 1)
                        )
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Open profile")
                    .accessibilityHint("Opens the user profile page with saved locations and app details.")
                }
            }
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.92),
                    Color(red: 0.90, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.45))
                .frame(width: 250, height: 250)
                .blur(radius: 28)
                .offset(x: 140, y: -300)
        }
    }

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionButton
            navigationButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private func primaryActionLabel(_ title: String, systemImage: String, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(Color(red: 0.15, green: 0.21, blue: 0.24))
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var connectionButton: some View {
        Button {
            toggleDemoConnection()
        } label: {
            primaryActionLabel(
                connectionManager.caneState.connectionStatus.rawValue,
                systemImage: connectionManager.caneState.connectionStatus == .connected ? "wifi" : "wifi.slash",
                detail: connectionManager.caneState.connectionStatus == .connected
                    ? "Tap to disconnect from \(connectionManager.activeEndpointLabel)."
                    : "Join the SmartCane Wi-Fi network, then tap to connect."
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection \(connectionManager.caneState.connectionStatus.rawValue)")
        .accessibilityHint(connectionManager.caneState.connectionStatus == .connected ? "Double-tap to disconnect the cane." : "Double-tap to connect to the cane over the SmartCane Wi-Fi network.")
    }

    private var navigationButton: some View {
        Button {
            showsNavigationSearch = true
        } label: {
            primaryActionLabel(
                locationManager.hasActiveNavigation ? locationManager.navigationStatusValue : "No current navigation",
                systemImage: locationManager.hasActiveNavigation ? "location.fill" : "magnifyingglass",
                detail: locationManager.hasActiveNavigation ? "Tap to change destination." : "Tap to search for a destination."
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locationManager.hasActiveNavigation ? "Current destination \(locationManager.navigationStatusValue)" : "No current navigation")
        .accessibilityHint(locationManager.hasActiveNavigation ? "Double-tap to change destination." : "Double-tap to search for a destination.")
    }

    private var vlmSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FastVLM runs on-device from Pi camera frames to provide scene-aware guidance.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink(destination: CVModelView()) {
                Text("Open FastVLM view")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open FastVLM view")
            .accessibilityHint("Opens live scene understanding output from Pi camera frames.")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.60), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private func toggleDemoConnection() {
        if connectionManager.caneState.connectionStatus == .connected {
            connectionManager.disconnectFromCane()
        } else {
            connectionManager.connectToCane()
        }
    }

    private func announceHomeSummary() {
        let navigation = locationManager.hasActiveNavigation
            ? "Navigating to \(locationManager.navigationStatusValue). Use Speak to change or stop."
            : "No active navigation. Use Speak to search."
        let pairing = connectionManager.pairedDevice.map {
            "Cane network \($0.deviceName)."
        } ?? "Join the SmartCane Wi-Fi network first."
        let connectionCommand = connectionManager.caneState.connectionStatus == .connected
            ? "Say disconnect cane to disconnect."
            : "Say connect cane after joining SmartCane Wi-Fi."
        let summary = "\(pairing) Cane \(connectionManager.caneState.connectionStatus.rawValue.lowercased()). \(navigation) \(connectionCommand)"
        speechManager.speak(summary, interrupt: true, force: true)
    }

    private var readMenuButton: some View {
        Button {
            announceHomeSummary()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .accessibilityHidden(true)
                Text("Read")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(Color(red: 0.32, green: 0.35, blue: 0.30), in: Capsule())
            .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Read menu")
        .accessibilityHint("Reads the current cane connection, navigation status, and available actions.")
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        let profileManager = ProfileManager()
        let connectionManager = CaneConnectionManager()
        let speechManager = SpeechManager()
        let visionManager = VisionManager(connectionManager: connectionManager)
        let fusionManager = GuidanceFusionManager(connectionManager: connectionManager, visionManager: visionManager)

        HomeView()
            .environmentObject(connectionManager)
            .environmentObject(LocationManager(profileManager: profileManager, connectionManager: connectionManager, fusionManager: fusionManager))
            .environmentObject(speechManager)
            .environmentObject(profileManager)
            .environmentObject(visionManager)
            .environmentObject(VoiceCommandManager())
    }
}
