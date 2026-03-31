/*
 File: HomeView.swift
 Purpose:
 This file is the main blind-first app screen.

 Layout:
 1. Cane connection
 2. Current destination
 3. Battery
 4. Live FastVLM scene output
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
                        batterySection
                        vlmSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Smart Cane")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsNavigationSearch) {
                NavigationView()
            }
            .onAppear {
                announceHomeSummary()
            }
            .onChange(of: connectionManager.caneState.connectionStatus) { newStatus in
                speechManager.speakUrgent("Cane connection \(newStatus.rawValue.lowercased()).")
                visionManager.setInferenceEnabled(newStatus == .connected)
            }
            .onChange(of: locationManager.currentInstruction) { newInstruction in
                guard locationManager.hasActiveNavigation else {
                    return
                }
                speechManager.speak(newInstruction, interrupt: true)
            }
            .onChange(of: connectionManager.caneState.batteryPercentage) { newBattery in
                if newBattery < 20 {
                    speechManager.speakUrgent("Warning. Cane battery low at \(newBattery) percent.")
                }
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
            networkModeControl
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
                    ? "Double-tap to disconnect. \(connectionManager.activeEndpointLabel)."
                    : "Double-tap to connect over Wi-Fi. \(connectionManager.networkModeDescription)"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection \(connectionManager.caneState.connectionStatus.rawValue)")
        .accessibilityHint(connectionManager.caneState.connectionStatus == .connected ? "Double-tap to disconnect the cane." : "Double-tap to connect the cane.")
    }

    private var navigationButton: some View {
        Button {
            showsNavigationSearch = true
        } label: {
            primaryActionLabel(
                locationManager.hasActiveNavigation ? locationManager.navigationStatusValue : "No current navigation",
                systemImage: locationManager.hasActiveNavigation ? "location.fill" : "magnifyingglass",
                detail: locationManager.hasActiveNavigation ? "Double-tap to change destination. \(locationManager.currentInstruction)" : "Double-tap to search for a destination."
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locationManager.hasActiveNavigation ? "Current destination \(locationManager.navigationStatusValue)" : "No current navigation")
        .accessibilityHint(locationManager.hasActiveNavigation ? "Double-tap to change destination." : "Double-tap to search for a destination.")
    }

    private var networkModeControl: some View {
        HStack(spacing: 10) {
            networkModeChip(.auto, label: "Auto")
            networkModeChip(.phoneHotspot, label: "Hotspot")
            networkModeChip(.piAccessPoint, label: "Pi AP")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cane network mode")
        .accessibilityHint("Choose hotspot or Pi access point transport profile.")
    }

    private func networkModeChip(_ mode: CaneNetworkMode, label: String) -> some View {
        let isSelected = connectionManager.caneState.networkMode == mode
        return Button {
            connectionManager.setNetworkMode(mode)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color(red: 0.15, green: 0.21, blue: 0.24))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isSelected
                    ? Color(red: 0.18, green: 0.34, blue: 0.37)
                    : Color.white.opacity(0.82),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) mode")
        .accessibilityHint(isSelected ? "Selected" : "Double tap to select")
    }

    private var batterySection: some View {
        NavigationLink(destination: BatteryView()) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 70, height: 70)

                        Image(systemName: batteryIconName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(batteryColor)
                            .accessibilityHidden(true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(connectionManager.caneState.batteryPercentage)%")
                            .font(.system(size: 32, weight: .bold, design: .rounded))

                        Text("Current cane battery")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.60), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cane battery: \(connectionManager.caneState.batteryPercentage) percent")
        .accessibilityHint("Opens the detailed battery screen.")
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

    private var batteryColor: Color {
        let battery = connectionManager.caneState.batteryPercentage

        if battery > 50 {
            return .green
        } else if battery >= 20 {
            return .orange
        } else {
            return .red
        }
    }

    private var batteryIconName: String {
        let battery = connectionManager.caneState.batteryPercentage

        if battery > 75 {
            return "battery.100"
        } else if battery > 50 {
            return "battery.75"
        } else if battery > 25 {
            return "battery.50"
        } else {
            return "battery.25"
        }
    }

    private func toggleDemoConnection() {
        if connectionManager.caneState.connectionStatus == .connected {
            connectionManager.disconnectFromCane()
        } else {
            connectionManager.connectToCane()
        }
    }

    private func announceHomeSummary() {
        let summary = "\(connectionManager.caneState.connectionStatus.rawValue). \(locationManager.hasActiveNavigation ? locationManager.navigationStatusValue : "No current navigation")"
        speechManager.speak(summary)
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        let profileManager = ProfileManager()
        let connectionManager = CaneConnectionManager()
        let speechManager = SpeechManager()

        HomeView()
            .environmentObject(connectionManager)
            .environmentObject(LocationManager(profileManager: profileManager, connectionManager: connectionManager))
            .environmentObject(speechManager)
            .environmentObject(profileManager)
    }
}
