import Foundation
import UIKit

@MainActor
final class VisionManager: ObservableObject {
    @Published var latestSceneSummary = "VLM idle"
    @Published var latestHazardTags: [String] = []
    @Published var inferenceEnabled = false
    @Published var latestFrameAgeMs: Int = 0

    private let connectionManager: CaneConnectionManager
    private var inferenceTask: Task<Void, Never>?
    private var latestFrameData: Data?
    private var latestFrameTimestamp = Date.distantPast

    init(connectionManager: CaneConnectionManager) {
        self.connectionManager = connectionManager
        connectionManager.registerFrameHandler { [weak self] frameData in
            Task { @MainActor in
                self?.latestFrameData = frameData
                self?.latestFrameTimestamp = Date()
            }
        }
    }

    func setInferenceEnabled(_ enabled: Bool) {
        inferenceEnabled = enabled
        if enabled {
            startInferenceLoop()
        } else {
            inferenceTask?.cancel()
            inferenceTask = nil
            publishSceneSummary("VLM idle")
            latestHazardTags = []
        }
    }

    private func startInferenceLoop() {
        inferenceTask?.cancel()
        inferenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                if let frame = self.latestFrameData {
                    let summary = await self.runFastVLM(on: frame)
                    self.processFastVLMOutput(summary)
                    self.latestFrameAgeMs = Int(Date().timeIntervalSince(self.latestFrameTimestamp) * 1000)
                }

                try? await Task.sleep(nanoseconds: 650_000_000)
            }
        }
    }

    private func runFastVLM(on frameData: Data) async -> String {
        if let fastVLMEngine {
            return await fastVLMEngine.inferHazardSummary(from: frameData)
        }

        guard let image = UIImage(data: frameData) else {
            return "Scene unclear due to decode failure"
        }

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let prompt = "Describe hazards relevant for blind cane guidance in one sentence."

        return "FastVLM pending SDK integration. Frame \(width)x\(height). Prompt: \(prompt)"
    }

    var fastVLMEngine: FastVLMEngine?

    private func processFastVLMOutput(_ rawOutput: String) {
        let normalized = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        let lowered = normalized.lowercased()
        var tags: [String] = []

        if lowered.contains("stair") {
            tags.append("stairs_ahead")
        }
        if lowered.contains("curb") {
            tags.append("curb")
        }
        if lowered.contains("crosswalk") {
            tags.append("crosswalk")
        }
        if lowered.contains("door") || lowered.contains("doorway") {
            tags.append("doorway")
        }
        if lowered.contains("person") || lowered.contains("pedestrian") {
            tags.append("pedestrian")
        }

        latestHazardTags = tags
        publishSceneSummary(normalized)
    }

    private func publishSceneSummary(_ summary: String) {
        latestSceneSummary = summary
        connectionManager.updateVLMSummary(summary)
    }
}

protocol FastVLMEngine {
    func inferHazardSummary(from jpegData: Data) async -> String
}
