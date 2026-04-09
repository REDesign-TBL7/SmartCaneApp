import Foundation
import Network

@MainActor
final class CaneConnectionManager: ObservableObject {
    @Published var caneState = CaneState()
    @Published var debugLogEntries: [DebugLogEntry] = []
    @Published var lastPingRoundTripMs: Int?

    private struct EndpointProfile {
        let mode: CaneNetworkMode
        let host: String
        let port: String
        let label: String
    }

    private let endpointProfiles: [EndpointProfile] = [
        EndpointProfile(mode: .phoneHotspot, host: "172.20.10.2", port: "8080", label: "Phone hotspot"),
        EndpointProfile(mode: .piAccessPoint, host: "192.168.4.1", port: "8080", label: "Pi access point")
    ]

    private var selectedEndpoint: EndpointProfile {
        let requestedMode = caneState.networkMode
        if requestedMode == .auto {
            return endpointProfiles[0]
        }

        return endpointProfiles.first(where: { $0.mode == requestedMode }) ?? endpointProfiles[0]
    }

    var networkModeDescription: String {
        switch caneState.networkMode {
        case .auto:
            return "Auto prefers phone hotspot, then Pi access point."
        case .phoneHotspot:
            return "Phone hotspot mode keeps cellular internet available while cane traffic stays local."
        case .piAccessPoint:
            return "Pi access point mode links directly to the cane network."
        }
    }

    var activeEndpointLabel: String {
        selectedEndpoint.label
    }
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var frameHandler: ((Data) -> Void)?
    private var savedRouteCommand: (command: NavigationCommand, instructionText: String)?
    private var isSafetyOverrideActive = false
    private var isVisionSafetyOverrideActive = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var latestPhoneLocation: (latitude: Double, longitude: Double)?
    private var pendingPingStartedAt: Date?

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "smartcane.path.monitor")
    private var isWiFiActive = false
    private var isCellularActive = false

    init() {
        caneState.connectionStatus = .disconnected
        caneState.currentInstruction = "No active navigation"
        caneState.currentNavigationCommand = .stop
        caneState.obstacleMessage = "No obstacles detected"
        caneState.statusMessage = "Waiting for Raspberry Pi connection"
        appendDebugLog("connection", "Manager initialized")

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.isWiFiActive = path.usesInterfaceType(.wifi)
                self.isCellularActive = path.usesInterfaceType(.cellular)
                self.appendDebugLog(
                    "network",
                    "Path updated. Wi-Fi \(self.isWiFiActive ? "up" : "down"), cellular \(self.isCellularActive ? "up" : "down")"
                )
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func registerFrameHandler(_ handler: @escaping (Data) -> Void) {
        frameHandler = handler
    }

    func connectToCane() {
        guard webSocketTask == nil, connectTask == nil else {
            appendDebugLog("connection", "Connect ignored because a session is already active")
            return
        }

        guard isWiFiActive else {
            caneState.connectionStatus = .disconnected
            caneState.statusMessage = "Connect to cane Wi-Fi first. Cellular remains available for internet only."
            appendDebugLog("connection", "Connect blocked because Wi-Fi is not active")
            return
        }

        caneState.connectionStatus = .connecting
        caneState.statusMessage = "Searching for cane endpoint over Wi-Fi"
        appendDebugLog("connection", "Starting connection probe for \(connectionCandidates().count) endpoint(s)")

        connectTask = Task { [weak self] in
            guard let self else {
                return
            }

            let endpoints = self.connectionCandidates()
            for endpoint in endpoints {
                self.caneState.statusMessage = "Probing \(endpoint.label) at \(endpoint.host):\(endpoint.port)"
                self.appendDebugLog("probe", "Probing \(endpoint.host):\(endpoint.port) for \(endpoint.label)")
                let reachable = await self.probeEndpoint(endpoint)
                if reachable {
                    self.appendDebugLog("probe", "Probe succeeded for \(endpoint.host):\(endpoint.port)")
                    self.openWebSocket(to: endpoint)
                    self.connectTask = nil
                    return
                }
                self.appendDebugLog("probe", "Probe failed for \(endpoint.host):\(endpoint.port)")
            }

            self.caneState.connectionStatus = .disconnected
            self.caneState.statusMessage = "No reachable cane endpoint found on Wi-Fi."
            self.appendDebugLog("connection", "All cane endpoint probes failed")
            self.connectTask = nil
        }
    }

    func setNetworkMode(_ mode: CaneNetworkMode) {
        caneState.networkMode = mode
        if caneState.connectionStatus == .connected {
            disconnectFromCane()
        }
        caneState.statusMessage = "Network mode set to \(mode.rawValue). \(networkModeDescription)"
        appendDebugLog("network", "Selected mode \(mode.rawValue)")
    }

    func disconnectFromCane() {
        appendDebugLog("connection", "Disconnect requested")
        connectTask?.cancel()
        connectTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession = nil

        caneState.connectionStatus = .disconnected
        caneState.currentNavigationCommand = .stop
        caneState.statusMessage = "Wi-Fi cane link closed"
        pendingPingStartedAt = nil
        lastPingRoundTripMs = nil
    }

    func sendNavigationCommand(_ command: NavigationCommand, instructionText: String) {
        if command == .stop {
            savedRouteCommand = nil
        } else {
            savedRouteCommand = (command, instructionText)
        }

        sendEffectiveNavigationCommand(command, instructionText: instructionText)
    }

    func sendDebugPing() {
        let label = "phone_ping_\(Int(Date().timeIntervalSince1970))"
        pendingPingStartedAt = Date()
        appendDebugLog("ping", "Sending DEBUG_PING \(label)")
        send(.debugPing(label: label))
    }

    func sendSafetyOverrideCommand(_ command: NavigationCommand, instructionText: String) {
        appendDebugLog("safety", "Safety override sending \(command.rawValue): \(instructionText)")
        sendRawNavigationCommand(command, instructionText: instructionText)
        isSafetyOverrideActive = true
    }

    func setVisionSafetyOverrideActive(_ isActive: Bool, reason: String) {
        if isActive == isVisionSafetyOverrideActive, isSafetyOverrideActive {
            return
        }

        isVisionSafetyOverrideActive = isActive
        if isActive {
            appendDebugLog("vision", "Vision safety override activated")
            sendSafetyOverrideCommand(.stop, instructionText: reason)
        } else {
            appendDebugLog("vision", "Vision safety override cleared")
            reevaluateSafetyOverride()
        }
    }

    func reevaluateSafetyOverride() {
        if shouldForceStopForImmediateSafety {
            guard !isSafetyOverrideActive || caneState.currentNavigationCommand != .stop else {
                return
            }

            sendSafetyOverrideCommand(.stop, instructionText: "Stopping for safety")
            return
        }

        guard isSafetyOverrideActive else {
            return
        }

        isSafetyOverrideActive = false
        if let savedRouteCommand {
            appendDebugLog("safety", "Resuming saved route command \(savedRouteCommand.command.rawValue)")
            sendRawNavigationCommand(savedRouteCommand.command, instructionText: savedRouteCommand.instructionText)
        } else {
            appendDebugLog("safety", "Safety override cleared with no saved route command")
            sendRawNavigationCommand(.stop, instructionText: "Safety override cleared")
        }
    }

    private var shouldForceStopForImmediateSafety: Bool {
        if caneState.faultCode != .none {
            return true
        }

        if isVisionSafetyOverrideActive {
            return true
        }

        let obstacle = caneState.nearestObstacleCm
        return obstacle >= 0 && obstacle < 45
    }

    private func sendEffectiveNavigationCommand(_ command: NavigationCommand, instructionText: String) {
        if shouldForceStopForImmediateSafety {
            sendSafetyOverrideCommand(.stop, instructionText: "Stopping for safety")
            return
        }

        isSafetyOverrideActive = false
        sendRawNavigationCommand(command, instructionText: instructionText)
    }

    private func sendRawNavigationCommand(_ command: NavigationCommand, instructionText: String) {
        caneState.currentNavigationCommand = command
        caneState.currentInstruction = instructionText

        appendDebugLog("command", "Sending \(command.rawValue): \(instructionText)")
        send(.command(command, instructionText: instructionText))
        caneState.statusMessage = "Sent Wi-Fi direction: \(command.rawValue)"
    }

    func updateVLMSummary(_ summary: String) {
        caneState.vlmSummary = summary
    }

    func updatePhoneLocation(latitude: Double, longitude: Double) {
        latestPhoneLocation = (latitude, longitude)
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                self.send(
                    .heartbeat(
                        vlmSummary: self.caneState.vlmSummary,
                        latitude: self.latestPhoneLocation?.latitude,
                        longitude: self.latestPhoneLocation?.longitude
                    )
                )

                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                guard let task = self.webSocketTask else {
                    return
                }

                do {
                    let message = try await task.receive()
                    self.appendDebugLog("socket", "Inbound message received")
                    self.handleInboundMessage(message)
                } catch {
                    self.caneState.faultCode = .heartbeatTimeout
                    self.caneState.statusMessage = "Connection dropped: \(error.localizedDescription)"
                    self.appendDebugLog("socket", "Receive failed: \(error.localizedDescription)")
                    self.disconnectFromCane()
                    return
                }
            }
        }
    }

    private func handleInboundMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            appendDebugLog("socket", "Inbound binary payload \(data.count) bytes")
            if let framePacket = try? decoder.decode(InboundFrameMessage.self, from: data),
               framePacket.type == "CAMERA_FRAME",
               let base64 = framePacket.jpegBase64,
               let frameData = Data(base64Encoded: base64) {
                appendDebugLog("frame", "Received camera frame \(frameData.count) bytes")
                frameHandler?(frameData)
                return
            }

            handleTelemetryData(data)
        case .string(let text):
            appendDebugLog("socket", "Inbound text payload \(text.count) chars")
            let data = Data(text.utf8)

            if let debugPong = try? decoder.decode(InboundDebugPongMessage.self, from: data),
               debugPong.type == "DEBUG_PONG" {
                let roundTripMs = pendingPingStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                lastPingRoundTripMs = roundTripMs
                pendingPingStartedAt = nil
                appendDebugLog("ping", "Received DEBUG_PONG \(debugPong.echo ?? "") RTT \(roundTripMs ?? -1) ms")
                return
            }

            if let framePacket = try? decoder.decode(InboundFrameMessage.self, from: data),
               framePacket.type == "CAMERA_FRAME",
               let base64 = framePacket.jpegBase64,
               let frameData = Data(base64Encoded: base64) {
                appendDebugLog("frame", "Received camera frame \(frameData.count) bytes")
                frameHandler?(frameData)
                return
            }

            handleTelemetryData(data)
        @unknown default:
            return
        }
    }

    private func handleTelemetryData(_ data: Data) {
        guard let telemetry = try? decoder.decode(InboundTelemetryMessage.self, from: data) else {
            appendDebugLog("telemetry", "Failed to decode inbound telemetry")
            return
        }

        appendDebugLog(
            "telemetry",
            "Obstacle \(telemetry.obstacleDistanceCm.map { String(Int($0)) } ?? "nil") cm, fault \(telemetry.faultCode?.rawValue ?? "nil"), gps \(telemetry.gpsFixStatus?.rawValue ?? "nil")"
        )

        if let obstacleDistanceCm = telemetry.obstacleDistanceCm {
            caneState.nearestObstacleCm = obstacleDistanceCm
            caneState.obstacleMessage = obstacleDistanceCm < 0 ? "Obstacle sensor unavailable" : "Nearest obstacle \(Int(obstacleDistanceCm)) cm"
        }

        if let motorImuAvailable = telemetry.motorImuAvailable {
            caneState.isMotorUnitIMUAvailable = motorImuAvailable
        }

        if let motorImuHeadingDegrees = telemetry.motorImuHeadingDegrees {
            caneState.motorUnitHeadingDegrees = motorImuHeadingDegrees
            caneState.isMotorUnitIMUAvailable = telemetry.motorImuAvailable ?? true
        } else if let headingDegrees = telemetry.headingDegrees {
            // Backward-compatible fallback for older Pi telemetry.
            caneState.motorUnitHeadingDegrees = headingDegrees
        }

        if let handleImuAvailable = telemetry.handleImuAvailable {
            caneState.isHandleIMUAvailable = handleImuAvailable
        }

        if let handleImuHeadingDegrees = telemetry.handleImuHeadingDegrees {
            caneState.handleIMUHeadingDegrees = handleImuHeadingDegrees
        }

        if let handleImuGyroZDegreesPerSecond = telemetry.handleImuGyroZDegreesPerSecond {
            caneState.handleIMUGyroZDegreesPerSecond = handleImuGyroZDegreesPerSecond
        }

        if let gpsFixStatus = telemetry.gpsFixStatus {
            caneState.gpsFixStatus = gpsFixStatus
        }

        if let faultCode = telemetry.faultCode {
            caneState.faultCode = faultCode
        }

        if let timestampMs = telemetry.timestampMs {
            caneState.lastTelemetryTimestampMs = timestampMs
        }

        if let statusMessage = telemetry.statusMessage {
            caneState.statusMessage = statusMessage
        } else if caneState.connectionStatus == .connected {
            caneState.statusMessage = connectionStatusSummary(connectedTo: selectedEndpoint)
        }

        reevaluateSafetyOverride()
    }

    private func connectionStatusSummary(connectedTo endpoint: EndpointProfile) -> String {
        let internetPath = isCellularActive ? "Cellular internet active" : "Cellular internet unavailable"
        return "Connected via \(endpoint.label). Cane traffic is Wi-Fi only. \(internetPath)."
    }

    private func connectionCandidates() -> [EndpointProfile] {
        if caneState.networkMode == .auto {
            return endpointProfiles
        }

        return [selectedEndpoint]
    }

    private func openWebSocket(to endpoint: EndpointProfile) {
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.port)/ws") else {
            caneState.connectionStatus = .disconnected
            caneState.statusMessage = "Invalid cane endpoint URL"
            appendDebugLog("connection", "Invalid WebSocket URL for \(endpoint.host):\(endpoint.port)")
            return
        }

        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = false

        let session = URLSession(configuration: config)
        urlSession = session
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        appendDebugLog("socket", "Opened WebSocket to \(url.absoluteString)")

        caneState.connectionStatus = .connected
        caneState.statusMessage = connectionStatusSummary(connectedTo: endpoint)

        startReceiveLoop()
        startHeartbeatLoop()
    }

    private func probeEndpoint(_ endpoint: EndpointProfile) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let port = UInt16(endpoint.port) else {
                continuation.resume(returning: false)
                return
            }

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: nwPort,
                using: .tcp
            )

            let queue = DispatchQueue(label: "smartcane.endpoint.probe")
            var didFinish = false

            let timeoutWork = DispatchWorkItem {
                if didFinish {
                    return
                }
                didFinish = true
                connection.cancel()
                continuation.resume(returning: false)
            }

            connection.stateUpdateHandler = { state in
                if didFinish {
                    return
                }

                switch state {
                case .ready:
                    didFinish = true
                    timeoutWork.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    didFinish = true
                    timeoutWork.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.2, execute: timeoutWork)
        }
    }

    private func send(_ payload: OutboundCaneMessage) {
        guard let task = webSocketTask else {
            appendDebugLog("socket", "Send dropped because WebSocket is not connected")
            return
        }

        guard let encoded = try? encoder.encode(payload),
              let text = String(data: encoded, encoding: .utf8) else {
            appendDebugLog("socket", "Failed to encode outbound payload \(payload.type)")
            return
        }

        appendDebugLog("socket", "Sending \(payload.type): \(text)")

        task.send(.string(text)) { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                Task { @MainActor in
                    self.caneState.statusMessage = "Send failed: \(error.localizedDescription)"
                    self.appendDebugLog("socket", "Send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func appendDebugLog(_ subsystem: String, _ message: String) {
        debugLogEntries.insert(DebugLogEntry(subsystem: subsystem, message: message), at: 0)
        if debugLogEntries.count > 200 {
            debugLogEntries.removeLast(debugLogEntries.count - 200)
        }
    }
}
