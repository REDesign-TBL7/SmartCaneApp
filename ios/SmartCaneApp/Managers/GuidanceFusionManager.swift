import Foundation

@MainActor
final class GuidanceFusionManager: ObservableObject {
    private let connectionManager: CaneConnectionManager
    private let visionManager: VisionManager

    init(connectionManager: CaneConnectionManager, visionManager: VisionManager) {
        self.connectionManager = connectionManager
        self.visionManager = visionManager
    }

    func applyFusedCommand(baseCommand: NavigationCommand, instructionText: String) {
        if shouldForceStopForSafety() {
            connectionManager.sendNavigationCommand(.stop, instructionText: "Stopping for safety")
            return
        }

        if visionManager.latestHazardTags.contains("stairs_ahead") {
            connectionManager.sendNavigationCommand(.stop, instructionText: "Stairs ahead. Stopping.")
            return
        }

        connectionManager.sendNavigationCommand(baseCommand, instructionText: instructionText)
    }

    private func shouldForceStopForSafety() -> Bool {
        if connectionManager.caneState.faultCode != .none {
            return true
        }

        let nearestObstacle = connectionManager.caneState.nearestObstacleCm
        if nearestObstacle >= 0, nearestObstacle < 45 {
            return true
        }

        return false
    }
}
