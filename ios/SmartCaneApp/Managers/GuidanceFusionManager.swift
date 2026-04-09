import Foundation
import Combine

@MainActor
final class GuidanceFusionManager: ObservableObject {
    private let connectionManager: CaneConnectionManager
    private let visionManager: VisionManager
    private var cancellables: Set<AnyCancellable> = []

    init(connectionManager: CaneConnectionManager, visionManager: VisionManager) {
        self.connectionManager = connectionManager
        self.visionManager = visionManager

        visionManager.$latestHazardTags
            .sink { [weak connectionManager] tags in
                connectionManager?.setVisionSafetyOverrideActive(
                    tags.contains("stairs_ahead"),
                    reason: "Stairs ahead. Stopping."
                )
            }
            .store(in: &cancellables)
    }

    func applyFusedCommand(baseCommand: NavigationCommand, instructionText: String) {
        connectionManager.sendNavigationCommand(baseCommand, instructionText: instructionText)
    }
}
