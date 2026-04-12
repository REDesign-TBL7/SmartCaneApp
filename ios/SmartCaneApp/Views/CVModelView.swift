import SwiftUI

struct CVModelView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var visionManager: VisionManager
    @EnvironmentObject private var bleDiagnosticsManager: BLEDiagnosticsManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.95, blue: 0.92),
                    Color(red: 0.90, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("On-device FastVLM")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("Pi camera frames processed on iPhone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    framePreviewCard
                    connectionDebugCard
                    bleDiagnosticsCard
                    vlmDebugCard
                    debugLogSection(title: "Connection Logs", entries: connectionManager.debugLogEntries)
                    debugLogSection(title: "Navigation Logs", entries: locationManager.debugLogEntries)
                    debugLogSection(title: "VLM Logs", entries: visionManager.debugLogEntries)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-device FastVLM screen")
        .accessibilityHint("Shows live scene understanding, phone to Pi connection diagnostics, and debug logs.")
        .onAppear {
            bleDiagnosticsManager.startScanning()
        }
        .onDisappear {
            bleDiagnosticsManager.stopScanning()
        }
    }

    private var framePreviewCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black)
                .frame(height: 220)
                .overlay {
                    if let preview = visionManager.latestFramePreview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        Text("Waiting for Pi camera frame")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityHidden(true)

            Text(visionManager.inferenceEnabled ? "Inference On" : "Inference Off")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(14)
        }
    }

    private var connectionDebugCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phone to Pi debug")
                .font(.subheadline.weight(.semibold))
            debugValueRow("Connection", connectionManager.caneState.connectionStatus.rawValue)
            debugValueRow("Endpoint", connectionManager.activeEndpointLabel)
            debugValueRow("Status", connectionManager.caneState.statusMessage)
            debugValueRow("Last ping", connectionManager.lastPingRoundTripMs.map { "\($0) ms" } ?? "Not tested yet")

            Button {
                connectionManager.sendDebugPing()
            } label: {
                Text("Send test ping to Pi")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send test ping to Pi")
            .accessibilityHint("Sends a debug ping through the WebSocket link and measures round trip time.")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var vlmDebugCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VLM debug")
                .font(.subheadline.weight(.semibold))
            debugValueRow("Scene summary", visionManager.latestSceneSummary)
            debugValueRow("Raw output", visionManager.latestRawModelOutput)
            debugValueRow("Hazard tags", visionManager.latestHazardTags.isEmpty ? "none" : visionManager.latestHazardTags.joined(separator: ", "))
            debugValueRow("Frame age", "\(visionManager.latestFrameAgeMs) ms")
            debugValueRow("Frame size", visionManager.latestFrameByteCount > 0 ? "\(visionManager.latestFrameByteCount) bytes" : "No frame yet")
            debugValueRow("Frame IMU", visionManager.latestFrameHandleIMUAvailable ? "Available" : "Unavailable")
            debugValueRow("Frame IMU heading", String(format: "%.1f deg", visionManager.latestFrameHandleIMUHeadingDegrees))
            debugValueRow("Frame IMU gyro Z", String(format: "%.2f dps", visionManager.latestFrameHandleIMUGyroZDegreesPerSecond))
            debugValueRow("Prompt", visionManager.latestPromptText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private var bleDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BLE diagnostics fallback")
                .font(.subheadline.weight(.semibold))
            debugValueRow("Bluetooth", bleDiagnosticsManager.bluetoothStateSummary)
            debugValueRow("Scanning", bleDiagnosticsManager.isScanning ? "Yes" : "No")
            debugValueRow("Provisioning", bleDiagnosticsManager.provisioningStateSummary)

            Button {
                if bleDiagnosticsManager.isScanning {
                    bleDiagnosticsManager.stopScanning()
                } else {
                    bleDiagnosticsManager.startScanning()
                }
            } label: {
                Text(bleDiagnosticsManager.isScanning ? "Stop BLE scan" : "Start BLE scan")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bleDiagnosticsManager.isScanning ? "Stop BLE diagnostics scan" : "Start BLE diagnostics scan")
            .accessibilityHint("Scans for SmartCane BLE beacons published by the Pi for debugging.")

            Button {
                bleDiagnosticsManager.readDetailedDiagnostics()
            } label: {
                Text(bleDiagnosticsManager.isReadingDetailedStatus ? "Reading BLE diagnostics..." : "Read detailed BLE diagnostics")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.white.opacity(0.82), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(bleDiagnosticsManager.isReadingDetailedStatus)
            .accessibilityLabel("Read detailed BLE diagnostics")
            .accessibilityHint("Connects to the Pi over BLE and reads detailed SmartCane status without changing Wi-Fi credentials.")

            VStack(alignment: .leading, spacing: 8) {
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
                    Text(bleDiagnosticsManager.isProvisioning ? "Provisioning..." : "Send hotspot credentials over BLE")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.82), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(bleDiagnosticsManager.isProvisioning)
            }

            if !bleDiagnosticsManager.latestProvisioningStatusPayload.isEmpty {
                if let status = bleDiagnosticsManager.latestProvisioningStatusSummary {
                    debugValueRow("Primary hotspot", status.primaryHotspotSSID ?? "Not set")
                    debugValueRow("Fallback hotspot", status.fallbackHotspotSSID ?? "Not set")
                    if !status.configuredNetworks.isEmpty {
                        debugValueRow("Configured networks", status.configuredNetworks.joined(separator: " -> "))
                    }
                    debugValueRow("Connected SSID", status.connectedSSID ?? "Not associated")
                    debugValueRow("Last connected", status.lastConnectedSSID ?? "None")
                    debugValueRow("Last attempted", status.lastAttemptedSSID ?? "None")
                    debugValueRow("Last failure", status.lastFailureReason ?? "None")
                    if !status.missingPackages.isEmpty {
                        debugValueRow("Missing packages", status.missingPackages.joined(separator: ", "))
                    }
                    if !status.recentMessages.isEmpty {
                        debugValueRow("Recent Pi messages", status.recentMessages.joined(separator: " | "))
                    }
                }
                debugValueRow("Provision payload", bleDiagnosticsManager.latestProvisioningStatusPayload)
            }

            if bleDiagnosticsManager.nearbyDevices.isEmpty {
                Text("No SmartCane BLE diagnostics beacons seen yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bleDiagnosticsManager.nearbyDevices.prefix(3)) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.name)
                            .font(.subheadline.weight(.semibold))
                        Text("RSSI \(device.rssi) dBm • seen \(device.lastSeenLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let parsed = device.parsedStatus {
                            debugValueRow("Mode", parsed.modeDescription ?? "Unknown")
                            debugValueRow("Runtime", boolText(parsed.runtimeActive))
                            debugValueRow("Hotspot Wi-Fi", boolText(parsed.wifiClientActive))
                            debugValueRow("App client", boolText(parsed.clientConnected))
                            debugValueRow("Runtime IP", parsed.runtimeIP ?? "Not assigned")
                            debugValueRow("Stage", parsed.stageDescription ?? "Unknown")
                            debugValueRow("Error", parsed.errorDescription ?? "Unknown")
                            if !parsed.recentEvents.isEmpty {
                                debugValueRow("Recent", parsed.recentEvents.joined(separator: " -> "))
                            }
                            if let rawStatusPage = parsed.rawStatusPage {
                                debugValueRow("BLE status page", rawStatusPage)
                            }
                            if let rawHistoryPage = parsed.rawHistoryPage {
                                debugValueRow("BLE history page", rawHistoryPage)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)

                    if device.id != bleDiagnosticsManager.nearbyDevices.prefix(3).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }

    private func debugValueRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else {
            return "Unknown"
        }
        return value ? "Yes" : "No"
    }

    private func debugLogSection(title: String, entries: [DebugLogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if entries.isEmpty {
                Text("No logs yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(12)) { entry in
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
                    if entry.id != entries.prefix(12).last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }
}

struct CVModelView_Previews: PreviewProvider {
    static var previews: some View {
        let connectionManager = CaneConnectionManager()
        let profileManager = ProfileManager()
        let visionManager = VisionManager(connectionManager: connectionManager)
        let fusionManager = GuidanceFusionManager(connectionManager: connectionManager, visionManager: visionManager)
        CVModelView()
            .environmentObject(connectionManager)
            .environmentObject(LocationManager(profileManager: profileManager, connectionManager: connectionManager, fusionManager: fusionManager))
            .environmentObject(visionManager)
            .environmentObject(BLEDiagnosticsManager())
    }
}
