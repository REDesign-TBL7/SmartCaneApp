import Foundation

#if canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
import CoreGraphics
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

enum FastVLMInferenceTask: Sendable {
    case sceneDescription
    case hazardClassification(obstacleDistanceCm: Int)
    case trafficLightCheck

    var prompt: String {
        switch self {
        case .sceneDescription:
            return """
            Describe only the visible scene in this camera frame.
            Mention concrete objects and layout that are actually visible.
            Do not guess or invent details.
            If the image is unclear, say exactly "Unclear image."
            Answer in one short sentence.
            """
        case .hazardClassification(let obstacleDistanceCm):
            return """
            The ultrasonic sensor reports an obstacle about \(obstacleDistanceCm) cm ahead.
            Identify the visible object directly ahead that may match this obstacle reading.
            Mention only what is clearly visible in front of the user.
            If no clear obstacle is visible, say exactly "Obstacle not visually confirmed."
            Answer in one short sentence.
            """
        case .trafficLightCheck:
            return """
            Look only for a pedestrian crossing signal or road traffic light relevant to crossing.
            If a signal is clearly visible, answer exactly one of:
            "Green light visible."
            "Red light visible."
            "Amber light visible."
            "Traffic signal visible but color unclear."
            If no such signal is clearly visible, answer exactly "No traffic signal visible."
            """
        }
    }
}

actor FastVLMAppleEngine: FastVLMEngine {
    private let generateParameters = GenerateParameters(temperature: 0.0)
    private var modelContainer: ModelContainer?
    private let inferenceImageSize = CGSize(width: 224, height: 224)
    private let maxTokens = 48

    private func loadIfNeeded() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        guard let modelDirectory = await MainActor.run(body: {
            FastVLMModelStore.existingInstalledModelDirectory()
        }) else {
            throw NSError(
                domain: "SmartCane.FastVLM",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "FastVLM model is not installed yet. Let the app finish downloading the model before using SmartCane."
                ]
            )
        }

        try await MainActor.run {
            try FastVLMModelStore.ensureChatTemplateFiles(in: modelDirectory)
        }
        try await FastVLMModelStore.ensureTokenizerMetadataIsUsable(in: modelDirectory)
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let configuration = ModelConfiguration(directory: modelDirectory)
        let container = try await VLMModelFactory.shared.loadContainer(
            configuration: configuration
        )
        modelContainer = container
        return container
    }

    func infer(from jpegData: Data, task: FastVLMInferenceTask) async -> String {
        guard let ciImage = CIImage(
            data: jpegData,
            options: [
                .applyOrientationProperty: true,
                .nearestSampling: false
            ]
        ) else {
            return "Scene unclear due to image decode failure"
        }

        do {
            let container = try await loadIfNeeded()
            let prompt = task.prompt
            let userInput: UserInput = {
                var input = UserInput(
                    prompt: prompt,
                    images: [.ciImage(ciImage)]
                )
                input.processing = .init(resize: inferenceImageSize)
                return input
            }()

            let output = try await container.perform { context in
                let preparedInput = try await context.processor.prepare(input: userInput)
                let result = try MLXLMCommon.generate(
                    input: preparedInput,
                    parameters: generateParameters,
                    context: context
                ) { tokens in
                    tokens.count >= maxTokens ? .stop : .more
                }
                return result.output
            }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Unclear image."
            }
            return Self.sanitizeModelOutput(trimmed, task: task)
        } catch {
            return "FastVLM inference failed: \(error.localizedDescription)"
        }
    }

    private static func sanitizeModelOutput(_ output: String, task: FastVLMInferenceTask) -> String {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()
        let cannedPhrases = [
            "immediate walking hazards",
            "uneven surfaces, obstacles, and sudden changes in direction",
            "person standing in front of green tree",
            "person standing infront of green tree",
            "construction site",
        ]
        if cannedPhrases.contains(where: { lowered.contains($0) }) {
            return fallback(for: task)
        }

        switch task {
        case .trafficLightCheck:
            let allowed = [
                "green light visible.",
                "red light visible.",
                "amber light visible.",
                "traffic signal visible but color unclear.",
                "no traffic signal visible.",
            ]
            if allowed.contains(lowered) {
                return normalized
            }
            return "No traffic signal visible."
        case .hazardClassification:
            let banned = [
                "tree",
                "construction site",
                "sudden changes in direction",
            ]
            if banned.contains(where: { lowered == $0 || lowered.contains("green tree") }) {
                return "Obstacle not visually confirmed."
            }
            return normalized
        case .sceneDescription:
            return normalized
        }
    }

    private static func fallback(for task: FastVLMInferenceTask) -> String {
        switch task {
        case .sceneDescription:
            return "Unclear image."
        case .hazardClassification:
            return "Obstacle not visually confirmed."
        case .trafficLightCheck:
            return "No traffic signal visible."
        }
    }
}

#endif
