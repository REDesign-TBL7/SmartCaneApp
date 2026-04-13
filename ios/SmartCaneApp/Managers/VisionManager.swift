import Combine
import Foundation
import ImageIO
import UIKit

@MainActor
final class VisionManager: ObservableObject {
    @Published var latestSceneSummary = "VLM idle"
    @Published var latestRawModelOutput = "VLM idle"
    @Published var latestHazardTags: [String] = []
    @Published var latestHazardAssessment = "No confirmed hazard"
    @Published var latestTrafficLightAssessment = "No traffic signal visible."
    @Published var latestInferenceMode = "Idle"
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
    private var previewTask: Task<Void, Never>?
    private var connectionStatusCancellable: AnyCancellable?
    private var latestFrameData: Data?
    private var latestFrameTimestamp = Date.distantPast
    private var latestFrameSequence: Int = 0
    private var lastProcessedFrameSequence: Int = -1
    private var lastInferenceStartedAt = Date.distantPast
    private var lastPreviewRenderedAt = Date.distantPast
    private var lastFrameLogAt = Date.distantPast
    private let latestPrompt = "Ultrasonic sensor gates hazard classification. Traffic-light checks run separately with exact-answer prompts."
    private let hazardDetectionThresholdCm = 150.0
    private let minimumSceneInferenceInterval: TimeInterval = 4.0
    private let minimumHazardInferenceInterval: TimeInterval = 1.2
    private let minimumTrafficInferenceInterval: TimeInterval = 3.0
    private let minimumPreviewInterval: TimeInterval = 0.35
    private let previewMaxPixelSize = 320
    private var lastSceneInferenceStartedAt = Date.distantPast
    private var lastHazardInferenceStartedAt = Date.distantPast
    private var lastTrafficInferenceStartedAt = Date.distantPast
    private struct InferenceSnapshot: Sendable {
        let frameData: Data
        let frameSequence: Int
        let frameTimestamp: Date
        let obstacleDistanceCm: Double
        let task: FastVLMInferenceTask
    }

    init(connectionManager: CaneConnectionManager) {
        self.connectionManager = connectionManager
        connectionManager.registerFrameHandler { [weak self] frameSample in
            Task { @MainActor [weak self] in
                self?.ingestFrame(frameSample)
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
        setInferenceEnabled(connectionManager.caneState.connectionStatus == .connected)
    }

    func setInferenceEnabled(_ enabled: Bool) {
        inferenceEnabled = enabled
        if enabled {
            if latestSceneSummary == "VLM idle" {
                publishSceneSummary("Waiting for Pi camera frame")
                latestRawModelOutput = "Waiting for Pi camera frame"
            }
            ensureInferenceLoopRunning()
        } else {
            inferenceTask?.cancel()
            inferenceTask = nil
            previewTask?.cancel()
            previewTask = nil
            lastProcessedFrameSequence = -1
            latestHazardAssessment = "No confirmed hazard"
            latestTrafficLightAssessment = "No traffic signal visible."
            latestInferenceMode = "Idle"
            publishSceneSummary("WebSocket not connected")
            latestRawModelOutput = "WebSocket not connected"
            latestFramePreview = nil
            latestFrameByteCount = 0
            latestHazardTags = []
            appendDebugLog("vision", "Inference disabled")
        }
    }

    private func ensureInferenceLoopRunning() {
        guard inferenceEnabled else {
            return
        }
        guard inferenceTask == nil else {
            return
        }
        appendDebugLog("vision", "Inference enabled")
        startInferenceLoop()
    }

    private func startInferenceLoop() {
        inferenceTask?.cancel()
        inferenceTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                if let snapshot = await self.nextInferenceSnapshot() {
                    let summary = await self.runFastVLM(on: snapshot.frameData, task: snapshot.task)
                    await MainActor.run {
                        self.processFastVLMOutput(summary, task: snapshot.task)
                        self.latestFrameAgeMs = Int(Date().timeIntervalSince(snapshot.frameTimestamp) * 1000)
                    }
                }

                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func runFastVLM(on frameData: Data, task: FastVLMInferenceTask) async -> String {
        let fastVLMEngine = await MainActor.run { self.fastVLMEngine }
        if let fastVLMEngine {
            await MainActor.run {
                self.appendDebugLog("inference", "Running FastVLM \(String(describing: task)) on \(frameData.count) bytes")
            }
            return await fastVLMEngine.infer(from: frameData, task: task)
        }

        guard let image = await Task.detached(priority: .utility, operation: {
            UIImage(data: frameData)
        }).value else {
            return "Scene unclear due to decode failure"
        }

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        await MainActor.run {
            self.appendDebugLog("inference", "FastVLM engine unavailable for frame \(width)x\(height)")
        }
        return "FastVLM engine unavailable in this build. Frame \(width)x\(height)."
    }

    var fastVLMEngine: FastVLMEngine?

    private func processFastVLMOutput(_ rawOutput: String, task: FastVLMInferenceTask) {
        let normalized = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        latestRawModelOutput = normalized
        latestInferenceMode = Self.label(for: task)

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

        switch task {
        case .hazardClassification:
            latestHazardAssessment = normalized
            latestHazardTags = tags
            publishSceneSummary(normalized)
        case .trafficLightCheck:
            latestTrafficLightAssessment = normalized
            if latestHazardAssessment == "No confirmed hazard" || latestHazardAssessment == "Obstacle not visually confirmed." {
                publishSceneSummary(normalized)
            }
        case .sceneDescription:
            if latestHazardAssessment == "No confirmed hazard" || latestHazardAssessment == "Obstacle not visually confirmed." {
                publishSceneSummary(normalized)
            }
            latestHazardTags = tags
        }
        appendDebugLog("inference", "Output: \(normalized)")
        appendDebugLog("hazards", "Tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))")
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

    private func nextInferenceSnapshot() -> InferenceSnapshot? {
        guard latestFrameSequence != lastProcessedFrameSequence,
              let frame = latestFrameData else {
            return nil
        }

        let obstacleDistanceCm = connectionManager.caneState.nearestObstacleCm
        let now = Date()
        let task: FastVLMInferenceTask
        if obstacleDistanceCm >= 0,
           obstacleDistanceCm <= hazardDetectionThresholdCm,
           now.timeIntervalSince(lastHazardInferenceStartedAt) >= minimumHazardInferenceInterval {
            task = .hazardClassification(obstacleDistanceCm: max(0, Int(obstacleDistanceCm.rounded())))
            lastHazardInferenceStartedAt = now
        } else if now.timeIntervalSince(lastTrafficInferenceStartedAt) >= minimumTrafficInferenceInterval {
            task = .trafficLightCheck
            lastTrafficInferenceStartedAt = now
        } else if now.timeIntervalSince(lastSceneInferenceStartedAt) >= minimumSceneInferenceInterval {
            task = .sceneDescription
            lastSceneInferenceStartedAt = now
        } else {
            return nil
        }

        lastProcessedFrameSequence = latestFrameSequence
        lastInferenceStartedAt = Date()
        return InferenceSnapshot(
            frameData: frame,
            frameSequence: latestFrameSequence,
            frameTimestamp: latestFrameTimestamp,
            obstacleDistanceCm: obstacleDistanceCm,
            task: task
        )
    }

    private func ingestFrame(_ frameSample: CaneConnectionManager.FrameSample) {
        let now = Date()
        latestFrameData = frameSample.jpegData
        latestFrameTimestamp = now
        latestFrameSequence += 1
        latestFrameByteCount = frameSample.jpegData.count
        latestFrameHandleIMUAvailable = frameSample.handleImuAvailable ?? false
        latestFrameHandleIMUHeadingDegrees = frameSample.handleImuHeadingDegrees ?? 0
        latestFrameHandleIMUGyroZDegreesPerSecond = frameSample.handleImuGyroZDegreesPerSecond ?? 0

        if now.timeIntervalSince(lastFrameLogAt) >= 1.0 {
            appendDebugLog(
                "frame",
                "Received latest frame \(frameSample.jpegData.count) bytes with handle IMU \(frameSample.handleImuAvailable == true ? "on" : "off") gyroZ \(Int(frameSample.handleImuGyroZDegreesPerSecond ?? 0))"
            )
            lastFrameLogAt = now
        }

        if connectionManager.caneState.connectionStatus == .connected {
            ensureInferenceLoopRunning()
        }

        if now.timeIntervalSince(lastPreviewRenderedAt) >= minimumPreviewInterval {
            schedulePreviewUpdateIfNeeded(for: frameSample.jpegData, sequence: latestFrameSequence)
        }
    }

    private func schedulePreviewUpdateIfNeeded(for jpegData: Data, sequence: Int) {
        guard previewTask == nil else {
            return
        }

        let previewMaxPixelSize = previewMaxPixelSize
        previewTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            let previewImage = Self.makePreviewImage(from: jpegData, maxPixelSize: previewMaxPixelSize)
            await MainActor.run {
                self.previewTask = nil
                if let previewImage, sequence == self.latestFrameSequence {
                    self.latestFramePreview = previewImage
                    self.lastPreviewRenderedAt = Date()
                }

                if sequence != self.latestFrameSequence,
                   let latestFrameData = self.latestFrameData,
                   Date().timeIntervalSince(self.lastPreviewRenderedAt) >= self.minimumPreviewInterval {
                    self.schedulePreviewUpdateIfNeeded(for: latestFrameData, sequence: self.latestFrameSequence)
                }
            }
        }
    }

    nonisolated private static func makePreviewImage(from jpegData: Data, maxPixelSize: Int) -> UIImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceShouldCache: false
            ]

            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            return UIImage(cgImage: thumbnail)
        }
    }

    private static func label(for task: FastVLMInferenceTask) -> String {
        switch task {
        case .sceneDescription:
            return "Scene"
        case .hazardClassification:
            return "Hazard"
        case .trafficLightCheck:
            return "Traffic Light"
        }
    }
}

protocol FastVLMEngine: Sendable {
    func infer(from jpegData: Data, task: FastVLMInferenceTask) async -> String
}
