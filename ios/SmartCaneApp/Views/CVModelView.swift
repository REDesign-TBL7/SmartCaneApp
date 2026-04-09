import SwiftUI

struct CVModelView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var visionManager: VisionManager

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
    }
}
