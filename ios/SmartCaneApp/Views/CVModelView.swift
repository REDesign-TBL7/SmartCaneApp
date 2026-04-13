import SwiftUI

struct CVModelView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager
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
                    visionSummaryCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-device FastVLM screen")
        .accessibilityHint("Shows live scene understanding from Pi camera frames.")
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
                        Text(frameOverlayMessage)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
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

    private var visionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vision summary")
                .font(.subheadline.weight(.semibold))
            debugValueRow("Scene", visionManager.latestSceneSummary)
            debugValueRow("Hazard", visionManager.latestHazardAssessment)
            debugValueRow("Traffic light", visionManager.latestTrafficLightAssessment)
            debugValueRow("Mode", visionManager.latestInferenceMode)
            debugValueRow("Frame status", frameStatusText)
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

    private var frameOverlayMessage: String {
        if connectionManager.caneState.connectionStatus != .connected {
            return "WebSocket not connected"
        }
        return "Waiting for Pi camera frame"
    }

    private var frameStatusText: String {
        if connectionManager.caneState.connectionStatus != .connected {
            return "WebSocket not connected"
        }
        return visionManager.latestFrameByteCount > 0 ? "Live camera frame received" : "Waiting for Pi camera frame"
    }

}

struct CVModelView_Previews: PreviewProvider {
    static var previews: some View {
        let visionManager = VisionManager(connectionManager: CaneConnectionManager())
        CVModelView()
            .environmentObject(visionManager)
    }
}
