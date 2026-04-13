import Foundation
import Combine

@MainActor
final class GuidanceFusionManager: ObservableObject {
    @Published private(set) var guidanceHeadline = "Connect the cane to start obstacle avoidance."
    @Published private(set) var guidanceDetail = "The demo focuses on near-field obstacle sensing, hazard confirmation, and turn guidance."
    @Published private(set) var trafficLightStatus = "No traffic signal visible."
    @Published private(set) var navigationStatus = "No active navigation"
    @Published private(set) var demoNarrative = "Connect the cane, then point it toward nearby obstacles to show short-range avoidance."
    @Published private(set) var isImmediateStopRecommended = false

    private let connectionManager: CaneConnectionManager
    private let visionManager: VisionManager
    private var cancellables: Set<AnyCancellable> = []
    private var routeBaseCommand: NavigationCommand = .stop
    private var routeInstructionText = "No active navigation"

    init(connectionManager: CaneConnectionManager, visionManager: VisionManager) {
        self.connectionManager = connectionManager
        self.visionManager = visionManager

        Publishers.CombineLatest(
            visionManager.$latestHazardTags,
            connectionManager.$caneState.map(\.nearestObstacleCm)
        )
            .sink { [weak connectionManager] tags, obstacleDistance in
                let shouldStop =
                    tags.contains("stairs_ahead")
                    || (obstacleDistance >= 0 && obstacleDistance < 80 && tags.contains("pedestrian"))
                    || (obstacleDistance >= 0 && obstacleDistance < 70 && tags.contains("curb"))
                    || (obstacleDistance >= 0 && obstacleDistance < 70 && tags.contains("doorway"))

                let reason: String
                if tags.contains("stairs_ahead") {
                    reason = "Stairs ahead. Stopping."
                } else if tags.contains("pedestrian"), obstacleDistance >= 0 {
                    reason = "Pedestrian about \(Int(obstacleDistance)) cm ahead. Stopping."
                } else if tags.contains("curb"), obstacleDistance >= 0 {
                    reason = "Curb detected about \(Int(obstacleDistance)) cm ahead. Stopping."
                } else if tags.contains("doorway"), obstacleDistance >= 0 {
                    reason = "Opening detected about \(Int(obstacleDistance)) cm ahead. Stopping."
                } else {
                    reason = "Stopping for safety."
                }

                connectionManager?.setVisionSafetyOverrideActive(shouldStop, reason: reason)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            connectionManager.$caneState,
            visionManager.$latestHazardAssessment,
            visionManager.$latestTrafficLightAssessment,
            visionManager.$latestInferenceMode
        )
            .sink { [weak self] caneState, hazardAssessment, trafficLightAssessment, inferenceMode in
                self?.recomputeGuidance(
                    caneState: caneState,
                    hazardAssessment: hazardAssessment,
                    trafficLightAssessment: trafficLightAssessment,
                    inferenceMode: inferenceMode
                )
            }
            .store(in: &cancellables)
    }

    func applyFusedCommand(baseCommand: NavigationCommand, instructionText: String) {
        routeBaseCommand = baseCommand
        routeInstructionText = instructionText
        dispatchFusedMotion()
    }

    private func recomputeGuidance(
        caneState: CaneState,
        hazardAssessment: String,
        trafficLightAssessment: String,
        inferenceMode: String
    ) {
        navigationStatus = caneState.currentInstruction
        trafficLightStatus = trafficLightAssessment

        let obstacleDistance = caneState.nearestObstacleCm
        let hasConfirmedHazard =
            hazardAssessment != "No confirmed hazard"
            && hazardAssessment != "Obstacle not visually confirmed."
            && hazardAssessment != "VLM idle"
            && !hazardAssessment.isEmpty

        if caneState.connectionStatus != .connected {
            guidanceHeadline = "Connect the cane to start obstacle avoidance."
            guidanceDetail = "The Pi streams camera frames while the ultrasonic sensor watches the near field."
            demoNarrative = "Connect the cane, then point it toward a nearby object to show detection and hazard confirmation."
            isImmediateStopRecommended = false
            dispatchFusedMotion()
            return
        }

        if obstacleDistance >= 0 && obstacleDistance < 45 {
            guidanceHeadline = "Immediate stop recommended"
            guidanceDetail = hasConfirmedHazard
                ? "\(hazardAssessment) Ultrasonic reports \(Int(obstacleDistance)) cm ahead."
                : "Obstacle detected \(Int(obstacleDistance)) cm ahead."
            demoNarrative = "The cane is in emergency stop range. \(guidanceDetail)"
            isImmediateStopRecommended = true
            dispatchFusedMotion()
            return
        }

        if obstacleDistance >= 0 && obstacleDistance < 90 {
            guidanceHeadline = "Obstacle close ahead"
            guidanceDetail = hasConfirmedHazard
                ? "\(hazardAssessment) About \(Int(obstacleDistance)) cm ahead."
                : "Obstacle detected \(Int(obstacleDistance)) cm ahead. Use short steering corrections."
            demoNarrative = "\(guidanceDetail) Navigation cue: \(caneState.currentInstruction)"
            isImmediateStopRecommended = false
            dispatchFusedMotion()
            return
        }

        if obstacleDistance >= 0 && obstacleDistance < 150 {
            guidanceHeadline = "Obstacle detected in short range"
            guidanceDetail = hasConfirmedHazard
                ? "\(hazardAssessment) About \(Int(obstacleDistance)) cm ahead."
                : "Obstacle detected \(Int(obstacleDistance)) cm ahead. Monitoring with camera confirmation."
            demoNarrative = "\(guidanceDetail) Navigation cue: \(caneState.currentInstruction)"
            isImmediateStopRecommended = false
            dispatchFusedMotion()
            return
        }

        guidanceHeadline = "Near field clear"
        if trafficLightAssessment != "No traffic signal visible." {
            guidanceDetail = "\(trafficLightAssessment) Navigation cue: \(caneState.currentInstruction)"
        } else if inferenceMode == "Scene", caneState.vlmSummary != "VLM idle", caneState.vlmSummary != "Waiting for Pi camera frame" {
            guidanceDetail = "\(caneState.vlmSummary) Navigation cue: \(caneState.currentInstruction)"
        } else {
            guidanceDetail = "No close obstacle detected. Navigation cue: \(caneState.currentInstruction)"
        }
        demoNarrative = guidanceDetail
        isImmediateStopRecommended = false
        dispatchFusedMotion()
    }

    private func dispatchFusedMotion() {
        let profile = commandProfile(
            baseCommand: routeBaseCommand,
            instructionText: routeInstructionText,
            caneState: connectionManager.caneState,
            latestTrafficLightAssessment: visionManager.latestTrafficLightAssessment
        )

        connectionManager.sendNavigationCommand(profile.command, instructionText: profile.instructionText)
    }

    private func commandProfile(
        baseCommand: NavigationCommand,
        instructionText: String,
        caneState: CaneState,
        latestTrafficLightAssessment: String
    ) -> (command: NavigationCommand, instructionText: String) {
        guard caneState.connectionStatus == .connected else {
            return (.stop, instructionText)
        }

        if isImmediateStopRecommended || caneState.faultCode.isBlockingMotionFault {
            return (.stop, "Stopping for safety")
        }

        let hasBlockingTrafficSignal =
            latestTrafficLightAssessment.localizedCaseInsensitiveContains("red")
            || latestTrafficLightAssessment.localizedCaseInsensitiveContains("do not cross")
            || latestTrafficLightAssessment.localizedCaseInsensitiveContains("don't cross")

        if hasBlockingTrafficSignal && baseCommand == .forward {
            return (.stop, "Traffic signal says do not cross")
        }

        switch baseCommand {
        case .forward:
            return (.forward, instructionText)
        case .left:
            return (.left, instructionText)
        case .right:
            return (.right, instructionText)
        case .stop:
            return (.stop, instructionText)
        }
    }
}
