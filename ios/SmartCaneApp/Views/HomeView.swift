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
    @EnvironmentObject private var fusionManager: GuidanceFusionManager
    @EnvironmentObject private var bleDiagnosticsManager: BLEDiagnosticsManager
    @State private var showsNavigationSearch = false
    @State private var showsConnectionAssistant = false

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        primaryActionsSection
                        diagnosticsShortcutSection
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
            .onChange(of: connectionManager.caneState.connectionStatus) { _, newStatus in
                speechManager.speakUrgent("Cane connection \(newStatus.rawValue.lowercased()).")
                visionManager.setInferenceEnabled(newStatus == .connected)
                if newStatus == .connected {
                    showsConnectionAssistant = false
                    bleDiagnosticsManager.endConnectionAssist()
                } else if newStatus == .disconnected,
                          connectionManager.hasKnownRuntimeEndpoint,
                          !showsConnectionAssistant {
                    let status = connectionManager.caneState.statusMessage.lowercased()
                    if status.contains("failed") {
                        bleDiagnosticsManager.beginConnectionAssist(autoConnect: true)
                        showsConnectionAssistant = true
                    }
                }
            }
            .sheet(isPresented: $showsConnectionAssistant, onDismiss: {
                bleDiagnosticsManager.endConnectionAssist()
            }) {
                ConnectionAssistantSheet()
                    .environmentObject(connectionManager)
                    .environmentObject(bleDiagnosticsManager)
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

    private var primaryActionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Main actions")
                .font(.headline.weight(.bold))
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
                connectionManager.caneState.connectionStatus == .connected ? "Disconnect cane" : "Connect cane",
                systemImage: connectionManager.caneState.connectionStatus == .connected ? "wifi" : "wifi.slash",
                detail: connectionManager.caneState.connectionStatus == .connected
                    ? "Connected to \(connectionManager.activeEndpointLabel)."
                    : "Use this to connect over the saved hotspot and Pi link."
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection \(connectionManager.caneState.connectionStatus.rawValue)")
        .accessibilityHint(connectionManager.caneState.connectionStatus == .connected ? "Double-tap to disconnect the cane." : "Double-tap to connect to the cane over the iPhone hotspot link.")
    }

    private var navigationButton: some View {
        Button {
            showsNavigationSearch = true
        } label: {
            primaryActionLabel(
                locationManager.hasActiveNavigation ? "Change destination" : "Choose destination",
                systemImage: locationManager.hasActiveNavigation ? "location.fill" : "magnifyingglass",
                detail: locationManager.hasActiveNavigation ? locationManager.navigationStatusValue : "Search for where to go."
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locationManager.hasActiveNavigation ? "Current destination \(locationManager.navigationStatusValue)" : "No current navigation")
        .accessibilityHint(locationManager.hasActiveNavigation ? "Double-tap to change destination." : "Double-tap to search for a destination.")
    }

    private var diagnosticsShortcutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("More")
                .font(.headline.weight(.bold))

            Text("Detailed obstacle status, camera analysis, BLE state, and logs are kept in Diagnostics.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink(destination: DiagnosticsView()) {
                Text("Open diagnostics")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open diagnostics")
            .accessibilityHint("Opens Pi connection, BLE provisioning, and debug logs.")
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
            if !connectionManager.connectToCane() {
                bleDiagnosticsManager.beginConnectionAssist(autoConnect: true)
                showsConnectionAssistant = true
            }
        }
    }

    private func announceHomeSummary() {
        let pairing = connectionManager.pairedDevice.map {
            "Cane network \($0.deviceName)."
        } ?? "Turn on Personal Hotspot and wait for BLE diagnostics to discover the Pi first."
        let connectionCommand = connectionManager.caneState.connectionStatus == .connected
            ? "Say disconnect cane to disconnect."
            : "Say connect cane after turning on Personal Hotspot."
        let summary = "\(pairing) Cane \(connectionManager.caneState.connectionStatus.rawValue.lowercased()). \(fusionManager.demoNarrative) \(connectionCommand)"
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
        let bleDiagnosticsManager = BLEDiagnosticsManager(connectionManager: connectionManager)

        HomeView()
            .environmentObject(connectionManager)
            .environmentObject(LocationManager(profileManager: profileManager, connectionManager: connectionManager, fusionManager: fusionManager))
            .environmentObject(speechManager)
            .environmentObject(profileManager)
            .environmentObject(visionManager)
            .environmentObject(fusionManager)
            .environmentObject(VoiceCommandManager())
            .environmentObject(bleDiagnosticsManager)
    }
}

private struct ConnectionAssistantSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var bleDiagnosticsManager: BLEDiagnosticsManager

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect over BLE")
                        .font(.title3.weight(.bold))
                    Text("The app is looking for the Pi over Bluetooth. If the Pi has not joined your hotspot yet, enter the hotspot details below and the app will connect as soon as the Pi reports an IP.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    assistantStatusCard
                    assistantProvisionCard
                }
                .padding(16)
            }
            .navigationTitle("Connect Pi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        bleDiagnosticsManager.endConnectionAssist()
                        dismiss()
                    }
                }
            }
            .onAppear {
                bleDiagnosticsManager.beginConnectionAssist(autoConnect: true)
            }
            .onChange(of: bleDiagnosticsManager.nearbyDevices.map(\.id)) { _, _ in
                guard !bleDiagnosticsManager.nearbyDevices.isEmpty,
                      !bleDiagnosticsManager.isReadingDetailedStatus,
                      !bleDiagnosticsManager.isProvisioning,
                      bleDiagnosticsManager.latestProvisioningStatusSummary == nil else {
                    return
                }
                bleDiagnosticsManager.readDetailedDiagnostics()
            }
            .onChange(of: connectionManager.caneState.connectionStatus) { _, newStatus in
                if newStatus == .connected {
                    dismiss()
                }
            }
        }
    }

    private var assistantStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            assistantValueRow("Bluetooth", bleDiagnosticsManager.bluetoothStateSummary)
            assistantValueRow("Scan", bleDiagnosticsManager.isScanning ? "Searching for Pi beacons" : "Scan stopped")
            assistantValueRow("Provisioning", bleDiagnosticsManager.provisioningStateSummary)
            assistantValueRow("Current status", connectionManager.caneState.statusMessage)

            if let status = bleDiagnosticsManager.latestProvisioningStatusSummary {
                assistantValueRow("Pi runtime IP", status.runtimeIP ?? "Not assigned")
                assistantValueRow("Connected SSID", status.connectedSSID ?? "Not associated")
                assistantValueRow("Last attempted SSID", status.lastAttemptedSSID ?? "None")
                assistantValueRow("Last failure", status.lastFailureReason ?? "None")
                if !status.recentMessages.isEmpty {
                    assistantValueRow("Recent Pi messages", status.recentMessages.joined(separator: " | "))
                }
            } else if let beacon = bleDiagnosticsManager.nearbyDevices.first?.parsedStatus {
                assistantValueRow("Beacon stage", beacon.stageDescription ?? "Unknown")
                assistantValueRow("Beacon error", beacon.errorDescription ?? "Unknown")
                assistantValueRow("Beacon IP", beacon.runtimeIP ?? "Not assigned")
            } else {
                Text("No Pi BLE beacon seen yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                bleDiagnosticsManager.readDetailedDiagnostics()
            } label: {
                Text(bleDiagnosticsManager.isReadingDetailedStatus ? "Reading Pi status..." : "Refresh Pi BLE status")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(bleDiagnosticsManager.isReadingDetailedStatus)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var assistantProvisionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hotspot details")
                .font(.subheadline.weight(.semibold))

            Text("Saved hotspot details are reused automatically when possible. If the Pi is waiting for credentials or the hotspot changed, edit them here and send again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Hotspot name", text: $bleDiagnosticsManager.hotspotSSIDDraft)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)

            SecureField("Hotspot password", text: $bleDiagnosticsManager.hotspotPasswordDraft)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)

            Button {
                bleDiagnosticsManager.provisionHotspot(
                    ssid: bleDiagnosticsManager.hotspotSSIDDraft,
                    password: bleDiagnosticsManager.hotspotPasswordDraft
                )
            } label: {
                Text(bleDiagnosticsManager.isProvisioning ? "Sending hotspot details..." : "Send hotspot details over BLE")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(bleDiagnosticsManager.isProvisioning)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private func assistantValueRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var visionManager: VisionManager
    @EnvironmentObject private var fusionManager: GuidanceFusionManager
    @EnvironmentObject private var bleDiagnosticsManager: BLEDiagnosticsManager
    @State private var showsDebugLogs = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                diagnosticsOverviewCard
                diagnosticsObstacleCard
                diagnosticsBLECard
                diagnosticsVisionCard
                advancedLogsSection
            }
            .padding(16)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.95, blue: 0.92),
                    Color(red: 0.90, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            bleDiagnosticsManager.startScanning()
        }
    }

    private var diagnosticsOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection overview")
                .font(.subheadline.weight(.semibold))
            diagnosticsValueRow("Connection", connectionManager.caneState.connectionStatus.rawValue)
            diagnosticsValueRow("Endpoint", connectionManager.activeEndpointLabel)
            diagnosticsValueRow("Status", connectionManager.caneState.statusMessage)
            diagnosticsValueRow("Last ping", connectionManager.lastPingRoundTripMs.map { "\($0) ms" } ?? "Not tested yet")

            Button {
                connectionManager.sendDebugPing()
            } label: {
                Text("Send test ping to Pi")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var diagnosticsBLECard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BLE provisioning")
                .font(.subheadline.weight(.semibold))
            diagnosticsValueRow("Bluetooth", bleDiagnosticsManager.bluetoothStateSummary)
            diagnosticsValueRow("Scan", bleDiagnosticsManager.isScanning ? "Active" : "Stopped")
            diagnosticsValueRow("Provisioning", bleDiagnosticsManager.provisioningStateSummary)

            if let status = bleDiagnosticsManager.latestProvisioningStatusSummary {
                diagnosticsValueRow("Primary hotspot", status.primaryHotspotSSID ?? "Not set")
                diagnosticsValueRow("Configured networks", status.configuredNetworks.isEmpty ? "None" : status.configuredNetworks.joined(separator: " -> "))
                diagnosticsValueRow("Connected SSID", status.connectedSSID ?? "Not associated")
                diagnosticsValueRow("Runtime IP", status.runtimeIP ?? "Not assigned")
                diagnosticsValueRow("Last attempted", status.lastAttemptedSSID ?? "None")
                diagnosticsValueRow("Last failure", status.lastFailureReason ?? "None")
                if !status.missingPackages.isEmpty {
                    diagnosticsValueRow("Missing packages", status.missingPackages.joined(separator: ", "))
                }
                if !status.recentMessages.isEmpty {
                    diagnosticsValueRow("Recent Pi messages", status.recentMessages.joined(separator: " | "))
                }
            } else if let device = bleDiagnosticsManager.nearbyDevices.first,
                      let parsed = device.parsedStatus {
                diagnosticsValueRow("Beacon stage", parsed.stageDescription ?? "Unknown")
                diagnosticsValueRow("Beacon error", parsed.errorDescription ?? "Unknown")
                diagnosticsValueRow("Beacon runtime IP", parsed.runtimeIP ?? "Not assigned")
            } else {
                Text("No SmartCane BLE devices seen yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                bleDiagnosticsManager.readDetailedDiagnostics()
            } label: {
                Text(bleDiagnosticsManager.isReadingDetailedStatus ? "Reading BLE diagnostics..." : "Refresh BLE diagnostics")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(bleDiagnosticsManager.isReadingDetailedStatus)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var diagnosticsObstacleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Short-range obstacle avoidance")
                .font(.subheadline.weight(.semibold))
            diagnosticsValueRow("Guidance", fusionManager.guidanceHeadline)
            diagnosticsValueRow("Detail", fusionManager.guidanceDetail)
            diagnosticsValueRow("Obstacle", connectionManager.caneState.obstacleMessage)
            diagnosticsValueRow("Navigation cue", locationManager.currentInstruction)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var diagnosticsVisionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vision status")
                .font(.subheadline.weight(.semibold))
            diagnosticsValueRow("Hazard", visionManager.latestHazardAssessment)
            diagnosticsValueRow("Traffic light", visionManager.latestTrafficLightAssessment)
            diagnosticsValueRow("Mode", visionManager.latestInferenceMode)

            NavigationLink(destination: CVModelView()) {
                Text("Open vision summary")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var advancedLogsSection: some View {
        DisclosureGroup(isExpanded: $showsDebugLogs) {
            VStack(alignment: .leading, spacing: 14) {
                diagnosticsLogSection(title: "Phone to Pi logs", entries: connectionManager.debugLogEntries)
                diagnosticsLogSection(title: "Navigation logs", entries: locationManager.debugLogEntries)
                diagnosticsLogSection(title: "Vision logs", entries: visionManager.debugLogEntries)
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced logs")
                    .font(.subheadline.weight(.semibold))
                Text("Hidden by default for the demo. Expand only when you need debugging.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private func diagnosticsLogSection(title: String, entries: [DebugLogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if entries.isEmpty {
                Text("No logs yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(20)) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(entry.timestampLabel) • \(entry.subsystem)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)

                    if entry.id != entries.prefix(20).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private func diagnosticsValueRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
