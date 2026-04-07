import SwiftUI

struct CVModelView: View {
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

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.black)
                            .frame(height: 180)
                            .overlay(
                                Text("Live Pi camera stream")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                            )
                            .accessibilityHidden(true)

                        Text(visionManager.inferenceEnabled ? "Inference On" : "Inference Off")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .padding(14)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Latest scene summary")
                            .font(.subheadline.weight(.semibold))
                        Text(visionManager.latestSceneSummary)
                            .font(.subheadline)
                        Text("Hazard tags: \(visionManager.latestHazardTags.isEmpty ? "none" : visionManager.latestHazardTags.joined(separator: ", "))")
                            .font(.subheadline)
                        Text("Frame age: \(visionManager.latestFrameAgeMs) ms")
                            .font(.subheadline)
                        Text("Inference is computed on-device from Pi camera frames and fed into guidance fusion.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("On-device FastVLM screen")
        .accessibilityHint("Shows live scene understanding from Pi camera frames.")
    }
}

struct CVModelView_Previews: PreviewProvider {
    static var previews: some View {
        let connectionManager = CaneConnectionManager()
        CVModelView()
            .environmentObject(VisionManager(connectionManager: connectionManager))
    }
}
