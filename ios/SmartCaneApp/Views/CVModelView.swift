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

            VStack(alignment: .leading, spacing: 20) {
                Text("On-device FastVLM")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("Pi camera frames processed on iPhone")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(Color.black)
                        .frame(height: 300)
                        .overlay(
                            Text("Live Pi camera stream")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        )
                        .accessibilityHidden(true)

                    Text(visionManager.inferenceEnabled ? "Inference On" : "Inference Off")
                        .font(.headline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(18)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Latest scene summary")
                        .font(.headline.weight(.semibold))
                    Text(visionManager.latestSceneSummary)
                        .font(.body)
                    Text("Hazard tags: \(visionManager.latestHazardTags.isEmpty ? \"none\" : visionManager.latestHazardTags.joined(separator: \", \") )")
                        .font(.body)
                    Text("Frame age: \(visionManager.latestFrameAgeMs) ms")
                        .font(.body)
                    Text("Inference is computed on-device from Pi camera frames and fed into guidance fusion.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
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
