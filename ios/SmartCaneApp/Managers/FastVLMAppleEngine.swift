import Foundation

#if canImport(FastVLM) && canImport(MLXVLM)
import CoreImage
import FastVLM
import MLXLMCommon
import MLXVLM

@MainActor
final class FastVLMAppleEngine: FastVLMEngine {
    private let modelConfiguration = FastVLM.FastVLM.modelConfiguration
    private let generateParameters = GenerateParameters(temperature: 0.0)
    private var modelContainer: ModelContainer?

    init() {
        FastVLM.FastVLM.register(modelFactory: VLMModelFactory.shared)
    }

    private func loadIfNeeded() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        let container = try await VLMModelFactory.shared.loadContainer(configuration: modelConfiguration)
        modelContainer = container
        return container
    }

    func inferHazardSummary(from jpegData: Data) async -> String {
        guard let ciImage = CIImage(data: jpegData) else {
            return "Scene unclear due to image decode failure"
        }

        do {
            let container = try await loadIfNeeded()
            let output = try await container.perform { context in
                let input = try await context.processor.prepare(
                    input: UserInput(
                        prompt: .text("Describe immediate walking hazards for a blind cane user in one short sentence."),
                        images: [.ciImage(ciImage)]
                    )
                )

                let result = try MLXLMCommon.generate(
                    input: input,
                    parameters: generateParameters,
                    context: context
                ) { tokens in
                    if tokens.count >= 48 {
                        return .stop
                    }
                    return .more
                }

                return result.output
            }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "No hazard details detected" : trimmed
        } catch {
            return "FastVLM inference failed: \(error.localizedDescription)"
        }
    }
}

#endif
