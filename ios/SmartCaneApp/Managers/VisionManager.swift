import Combine
import Foundation
import UIKit

@MainActor
final class VisionManager: ObservableObject {
    @Published var latestSceneSummary = "VLM idle"
    @Published var latestRawModelOutput = "VLM idle"
    @Published var latestHazardTags: [String] = []
    @Published var inferenceEnabled = false
    @Published var latestFrameAgeMs: Int = 0
    @Published var latestFramePreview: UIImage?
    @Published var latestFrameByteCount: Int = 0
    @Published var latestFrameHandleIMUAvailable = false
    @Published var latestFrameHandleIMUHeadingDegrees: Double = 0
    @Published var latestFrameHandleIMUGyroZDegreesPerSecond: Double = 0
    @Published var debugLogEntries: [DebugLogEntry] = []

    private let connectionManager: CaneConnectionManager
    private var inferenceTask: Task<Void, Never>?
    private var connectionStatusCancellable: AnyCancellable?
    private var latestFrameData: Data?
    private var latestFrameTimestamp = Date.distantPast
    private var latestFrameSequence: Int = 0
    private var lastProcessedFrameSequence: Int = -1
    private let latestPrompt = "Describe hazards relevant for blind cane guidance in one sentence."

    init(connectionManager: CaneConnectionManager) {
        self.connectionManager = connectionManager
        connectionManager.registerFrameHandler { [weak self] frameSample in
            Task { @MainActor in
                self?.latestFrameData = frameSample.jpegData
                self?.latestFrameTimestamp = Date()
                self?.latestFrameSequence += 1
                self?.latestFrameByteCount = frameSample.jpegData.count
                self?.latestFramePreview = UIImage(data: frameSample.jpegData)
                self?.latestFrameHandleIMUAvailable = frameSample.handleImuAvailable ?? false
                self?.latestFrameHandleIMUHeadingDegrees = frameSample.handleImuHeadingDegrees ?? 0
                self?.latestFrameHandleIMUGyroZDegreesPerSecond = frameSample.handleImuGyroZDegreesPerSecond ?? 0
                self?.appendDebugLog(
                    "frame",
                    "Received frame \(frameSample.jpegData.count) bytes with handle IMU \(frameSample.handleImuAvailable == true ? "on" : "off") gyroZ \(Int(frameSample.handleImuGyroZDegreesPerSecond ?? 0))"
                )
            }
        }
        connectionStatusCancellable = connectionManager.$caneState
            .map(\.connectionStatus)
            .removeDuplicates()
            .sink { [weak self] status in
                Task { @MainActor in
                    self?.setInferenceEnabled(status == .connected)
                }
            }
        appendDebugLog("vision", "Vision manager initialized")
    }

    func setInferenceEnabled(_ enabled: Bool) {
        inferenceEnabled = enabled
        if enabled {
            if inferenceTask != nil {
                return
            }
            appendDebugLog("vision", "Inference enabled")
            startInferenceLoop()
        } else {
            inferenceTask?.cancel()
            inferenceTask = nil
            lastProcessedFrameSequence = -1
            publishSceneSummary("VLM idle")
            latestHazardTags = []
            appendDebugLog("vision", "Inference disabled")
        }
    }

    private func startInferenceLoop() {
        inferenceTask?.cancel()
        inferenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                if self.latestFrameSequence != self.lastProcessedFrameSequence,
                   let frame = self.latestFrameData {
                    self.lastProcessedFrameSequence = self.latestFrameSequence
                    let summary = await self.runFastVLM(on: frame)
                    self.processFastVLMOutput(summary)
                    self.latestFrameAgeMs = Int(Date().timeIntervalSince(self.latestFrameTimestamp) * 1000)
                }

                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func runFastVLM(on frameData: Data) async -> String {
        if let fastVLMEngine {
            appendDebugLog("inference", "Running FastVLM engine on \(frameData.count) bytes")
            return await fastVLMEngine.inferHazardSummary(from: frameData)
        }

        guard let image = UIImage(data: frameData) else {
            return "Scene unclear due to decode failure"
        }

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        appendDebugLog("inference", "Using placeholder inference on frame \(width)x\(height)")
        return "FastVLM pending SDK integration. Frame \(width)x\(height). Prompt: \(latestPrompt)"
    }

    var fastVLMEngine: FastVLMEngine?

    private func processFastVLMOutput(_ rawOutput: String) {
        let normalized = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        latestRawModelOutput = normalized

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
        appendDebugLog("inference", "Output: \(normalized)")
        appendDebugLog("hazards", "Tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))")
        publishSceneSummary(normalized)
    }

    private func publishSceneSummary(_ summary: String) {
        latestSceneSummary = summary
        connectionManager.updateVLMSummary(summary)
    }

    var latestPromptText: String {
        latestPrompt
    }

    private func appendDebugLog(_ subsystem: String, _ message: String) {
        debugLogEntries.insert(DebugLogEntry(subsystem: subsystem, message: message), at: 0)
        if debugLogEntries.count > 160 {
            debugLogEntries.removeLast(debugLogEntries.count - 160)
        }
    }
}

protocol FastVLMEngine {
    func inferHazardSummary(from jpegData: Data) async -> String
}
