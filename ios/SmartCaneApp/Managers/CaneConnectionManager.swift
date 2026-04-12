import Foundation
import Network
import Darwin

@MainActor
final class CaneConnectionManager: ObservableObject {
    @Published var caneState = CaneState()
    @Published var debugLogEntries: [DebugLogEntry] = []
    @Published var lastPingRoundTripMs: Int?
    @Published private(set) var pairedDevice: PairedCaneDevice?
    private struct EndpointProfile {
        let host: String
        let port: String
        let path: String
        let label: String
    }

    struct FrameSample {
        let jpegData: Data
        let timestampMs: Int64?
        let handleImuAvailable: Bool?
        let handleImuHeadingDegrees: Double?
        let handleImuGyroZDegreesPerSecond: Double?
    }

    private final class ProbeCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !didFinish else {
                return false
            }

            didFinish = true
            return true
        }
    }


    private enum PairingError: LocalizedError {
        case invalidURL
        case handshakeTimedOut
        case invalidResponse
        case missingDeviceInfo
        case deviceMismatch

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid cane URL"
            case .handshakeTimedOut:
                return "Pairing timed out"
            case .invalidResponse:
                return "Unexpected pairing response"
            case .missingDeviceInfo:
                return "Cane did not provide a device name or ID"
            case .deviceMismatch:
                return "Connected to the wrong cane"
            }
        }
    }

    private struct EstablishedSession {
        let session: URLSession
        let task: URLSessionWebSocketTask
        let endpoint: EndpointProfile
        let pairedDevice: PairedCaneDevice
    }

    private let hotspotLabel = "iPhone Personal Hotspot"
    private let pairingStorageKey = "smart_cane_paired_device"
    private let runtimePort = "8080"
    private let runtimePath = "/ws"
    private let mdnsRuntimeHost = "smartcane-pi.local"
    private let bonjourServiceType = "_smartcane._tcp."

    private var currentEndpoint: EndpointProfile?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var connectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var frameHandler: ((FrameSample) -> Void)?
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
    private var activeBonjourLookup: BonjourLookup?

    init() {
        pairedDevice = Self.loadPairedDevice(storageKey: pairingStorageKey)
        caneState.connectionStatus = .disconnected
        caneState.currentInstruction = "No active navigation"
        caneState.currentNavigationCommand = .stop
        caneState.obstacleMessage = "No obstacles detected"
        caneState.statusMessage = Self.disconnectedStatusMessage(for: pairedDevice)
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

    var networkModeDescription: String {
        "Turn on iPhone Personal Hotspot. The Pi joins it, BLE diagnostics reports the Pi IP, and the app connects to that runtime endpoint."
    }

    var activeEndpointLabel: String {
        if let currentEndpoint {
            return "\(currentEndpoint.label) @ \(currentEndpoint.host):\(currentEndpoint.port)"
        }

        if let pairedDevice {
            return "\(pairedDevice.deviceName) @ \(pairedDevice.host):\(pairedDevice.port)"
        }

        return hotspotLabel
    }

    var hasKnownRuntimeEndpoint: Bool {
        !connectionCandidates().isEmpty
    }

    func registerFrameHandler(_ handler: @escaping (FrameSample) -> Void) {
        frameHandler = handler
    }

    @discardableResult
    func connectToCane() -> Bool {
        guard webSocketTask == nil, connectTask == nil else {
            appendDebugLog("connection", "Connect ignored because a session is already active")
            return false
        }

        let candidates = connectionCandidates()
        guard !candidates.isEmpty else {
            caneState.connectionStatus = .disconnected
            caneState.statusMessage = "No Pi runtime address is known yet. The app is waiting for mDNS or BLE discovery."
            appendDebugLog("connection", "Connect blocked because no runtime endpoint candidates are available yet")
            return false
        }

        caneState.connectionStatus = .connecting
        if !isWiFiActive && !isCellularActive {
            appendDebugLog(
                "network",
                "Neither Wi-Fi nor cellular is reported by iOS path monitor; still attempting hotspot connection"
            )
        }
        connectTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.connectToRuntime(candidates)
        }
        return true
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
        currentEndpoint = nil

        caneState.connectionStatus = .disconnected
        caneState.currentNavigationCommand = .stop
        caneState.statusMessage = Self.disconnectedStatusMessage(for: pairedDevice)
        pendingPingStartedAt = nil
        lastPingRoundTripMs = nil
    }

    func forgetPairedCane() {
        if caneState.connectionStatus == .connected {
            disconnectFromCane()
        }

        pairedDevice = nil
        UserDefaults.standard.removeObject(forKey: pairingStorageKey)
        caneState.statusMessage = Self.disconnectedStatusMessage(for: nil)
        appendDebugLog("pairing", "Cleared saved hotspot endpoint")
    }

    func rememberProvisionedCane(deviceID: String, deviceName: String, wsPath: String = "/ws") {
        let trimmedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDeviceID.isEmpty, !trimmedDeviceName.isEmpty else {
            appendDebugLog("pairing", "Skipped provisional pairing save because setup response was incomplete")
            return
        }

        guard let host = pairedDevice?.host else {
            appendDebugLog("pairing", "Skipped provisional pairing save because no hotspot runtime host has been discovered yet")
            return
        }

        let pairedDevice = PairedCaneDevice(
            deviceID: trimmedDeviceID,
            deviceName: trimmedDeviceName,
            host: host,
            port: runtimePort,
            wsPath: wsPath,
            pairedAt: Date()
        )
        savePairedDevice(pairedDevice)
        caneState.statusMessage = "Saved \(trimmedDeviceName) at hotspot endpoint \(host):\(runtimePort)."
        appendDebugLog("pairing", "Saved hotspot device profile for \(pairedDevice.summaryText) at \(host)")
    }

    func updateDiscoveredRuntimeHost(host: String, deviceName: String? = nil, wsPath: String = "/ws") {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, trimmedHost != "0.0.0.0" else {
            return
        }

        let normalizedPath = Self.normalizedPath(wsPath, fallback: runtimePath)
        let existing = pairedDevice
        let trimmedDeviceName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedDeviceName = !trimmedDeviceName.isEmpty
            ? trimmedDeviceName
            : existing?.deviceName ?? "SmartCane"
        let updated = PairedCaneDevice(
            deviceID: existing?.deviceID ?? "smartcane-hotspot-client",
            deviceName: resolvedDeviceName,
            host: trimmedHost,
            port: runtimePort,
            wsPath: normalizedPath,
            pairedAt: existing?.pairedAt ?? Date()
        )

        guard existing != updated else {
            return
        }

        savePairedDevice(updated)
        if caneState.connectionStatus != .connected {
            caneState.statusMessage = "Pi discovered at \(trimmedHost). Turn on Personal Hotspot, then connect."
        }
        appendDebugLog("ble", "Discovered hotspot runtime endpoint \(trimmedHost):\(runtimePort)\(normalizedPath)")
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

    func updateVLMSummary(_ summary: String) {
        caneState.vlmSummary = summary
    }

    func updatePhoneLocation(latitude: Double, longitude: Double) {
        latestPhoneLocation = (latitude, longitude)
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

    private func connectToRuntime(_ candidates: [EndpointProfile]) async {
        let pairedAt = pairedDevice?.pairedAt ?? Date()
        let expectedDeviceID = pairedDevice?.deviceID
        appendDebugLog(
            "connection",
            "Trying runtime endpoints: \(candidates.map { "\($0.host):\($0.port)" }.joined(separator: ", "))"
        )

        var lastError: Error?
        for endpoint in candidates {
            appendDebugLog("connection", "Connecting to runtime at \(endpoint.host):\(endpoint.port)\(endpoint.path)")
            do {
                let established = try await establishRuntimeSession(
                    to: endpoint,
                    expectedDeviceID: expectedDeviceID,
                    pairedAt: pairedAt
                )
                savePairedDevice(established.pairedDevice)
                adoptOpenWebSocket(
                    session: established.session,
                    task: established.task,
                    endpoint: established.endpoint
                )
                connectTask = nil
                return
            } catch {
                lastError = error
                appendDebugLog("connection", "Runtime connection failed at \(endpoint.host): \(error.localizedDescription)")
            }
        }

        if let bonjourEndpoint = await discoverBonjourEndpoint(excluding: candidates.map(\.host)) {
            appendDebugLog("bonjour", "Resolved Bonjour runtime at \(bonjourEndpoint.host):\(bonjourEndpoint.port)\(bonjourEndpoint.path)")
            do {
                let established = try await establishRuntimeSession(
                    to: bonjourEndpoint,
                    expectedDeviceID: expectedDeviceID,
                    pairedAt: pairedAt
                )
                savePairedDevice(established.pairedDevice)
                adoptOpenWebSocket(
                    session: established.session,
                    task: established.task,
                    endpoint: established.endpoint
                )
                connectTask = nil
                return
            } catch {
                lastError = error
                appendDebugLog("bonjour", "Bonjour runtime connection failed: \(error.localizedDescription)")
            }
        } else {
            appendDebugLog("bonjour", "No Bonjour runtime service resolved")
        }

        caneState.connectionStatus = .disconnected
        caneState.statusMessage = "Connection failed. The app tried the saved endpoint, smartcane-pi.local, and Bonjour service discovery. Use BLE diagnostics to refresh the Pi address."
        if let lastError {
            appendDebugLog("connection", "All runtime connection attempts failed: \(lastError.localizedDescription)")
        }
        connectTask = nil
    }

    private func establishRuntimeSession(
        to endpoint: EndpointProfile,
        expectedDeviceID: String?,
        pairedAt: Date
    ) async throws -> EstablishedSession {
        guard let url = makeWebSocketURL(for: endpoint) else {
            throw PairingError.invalidURL
        }

        appendDebugLog("connection", "Probing \(endpoint.host):\(endpoint.port)")
        guard await probeEndpoint(endpoint) else {
            throw PairingError.handshakeTimedOut
        }

        let session = URLSession(configuration: makeLocalNetworkConfiguration())
        let task = session.webSocketTask(with: url)
        task.resume()

        appendDebugLog("pairing", "Opened socket to \(url.absoluteString)")
        try await sendImmediately(.pairHello(clientName: "SmartCane iPhone"), on: task)
        appendDebugLog("pairing", "Sent PAIR_HELLO")

        let response = try await receivePairInfo(on: task)
        guard let deviceID = response.deviceID, !deviceID.isEmpty,
              let deviceName = response.deviceName, !deviceName.isEmpty else {
            throw PairingError.missingDeviceInfo
        }

        if let expectedDeviceID, expectedDeviceID != deviceID {
            task.cancel(with: .normalClosure, reason: nil)
            throw PairingError.deviceMismatch
        }

        let resolvedPath = Self.normalizedPath(response.wsPath ?? endpoint.path, fallback: "/ws")
        let resolvedEndpoint = EndpointProfile(
            host: endpoint.host,
            port: endpoint.port,
            path: resolvedPath,
            label: deviceName
        )

        return EstablishedSession(
            session: session,
            task: task,
            endpoint: resolvedEndpoint,
            pairedDevice: PairedCaneDevice(
                deviceID: deviceID,
                deviceName: deviceName,
                host: endpoint.host,
                port: endpoint.port,
                wsPath: resolvedPath,
                pairedAt: pairedAt
            )
        )
    }

    private func receivePairInfo(on task: URLSessionWebSocketTask) async throws -> InboundPairInfoMessage {
        let deadline = Date().addingTimeInterval(3.0)

        while Date() < deadline {
            let secondsRemaining = max(0.1, deadline.timeIntervalSinceNow)
            let message = try await withTimeout(seconds: secondsRemaining) {
                try await task.receive()
            }

            let data: Data
            switch message {
            case .data(let payload):
                data = payload
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                continue
            }

            if let response = try? decoder.decode(InboundPairInfoMessage.self, from: data),
               response.type == "PAIR_INFO" {
                return response
            }

            appendDebugLog("pairing", "Skipping pre-handshake \(payloadTypeDescription(for: data)) message")
        }

        throw PairingError.handshakeTimedOut
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PairingError.handshakeTimedOut
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
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
                guard let self, let task = self.webSocketTask else {
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
                frameHandler?(
                    FrameSample(
                        jpegData: frameData,
                        timestampMs: framePacket.timestampMs,
                        handleImuAvailable: framePacket.handleImuAvailable,
                        handleImuHeadingDegrees: framePacket.handleImuHeadingDegrees,
                        handleImuGyroZDegreesPerSecond: framePacket.handleImuGyroZDegreesPerSecond
                    )
                )
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
                frameHandler?(
                    FrameSample(
                        jpegData: frameData,
                        timestampMs: framePacket.timestampMs,
                        handleImuAvailable: framePacket.handleImuAvailable,
                        handleImuHeadingDegrees: framePacket.handleImuHeadingDegrees,
                        handleImuGyroZDegreesPerSecond: framePacket.handleImuGyroZDegreesPerSecond
                    )
                )
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
        } else if caneState.connectionStatus == .connected, let currentEndpoint {
            caneState.statusMessage = connectionStatusSummary(connectedTo: currentEndpoint)
        }

        reevaluateSafetyOverride()
    }

    private func connectionStatusSummary(connectedTo endpoint: EndpointProfile) -> String {
        let internetPath = isCellularActive ? "Personal Hotspot is using cellular backhaul" : "Local hotspot path active"
        if let pairedDevice {
            return "Connected to \(pairedDevice.deviceName) at \(endpoint.host):\(endpoint.port) over Personal Hotspot. \(internetPath)."
        }

        return "Connected to Pi runtime at \(endpoint.host):\(endpoint.port) over Personal Hotspot. \(internetPath)."
    }

    private func adoptOpenWebSocket(
        session: URLSession,
        task: URLSessionWebSocketTask,
        endpoint: EndpointProfile
    ) {
        urlSession = session
        webSocketTask = task
        currentEndpoint = endpoint

        caneState.connectionStatus = .connected
        caneState.statusMessage = connectionStatusSummary(connectedTo: endpoint)

        if endpoint.host == "192.168.4.1" {
            appendDebugLog("connection", "Sending AP test confirmation for legacy AP rollback flow")
            send(.confirmAPTest(clientName: "SmartCane iPhone"))
        }
        startReceiveLoop()
        startHeartbeatLoop()
    }

    private func probeEndpoint(_ endpoint: EndpointProfile) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let port = UInt16(endpoint.port),
                  let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: nwPort,
                using: .tcp
            )

            let queue = DispatchQueue(label: "smartcane.endpoint.probe")
            let finishGate = ProbeCompletionGate()

            let timeoutWork = DispatchWorkItem {
                guard finishGate.claim() else {
                    return
                }
                connection.cancel()
                continuation.resume(returning: false)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard finishGate.claim() else {
                        return
                    }
                    timeoutWork.cancel()
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard finishGate.claim() else {
                        return
                    }
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

        do {
            let encoded = try encoder.encode(payload)
            guard let text = String(data: encoded, encoding: .utf8) else {
                appendDebugLog("socket", "Failed to convert outbound payload \(payload.type) to text")
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
        } catch {
            appendDebugLog("socket", "Failed to encode outbound payload \(payload.type)")
        }
    }

    private func sendImmediately(_ payload: OutboundCaneMessage, on task: URLSessionWebSocketTask) async throws {
        let encoded = try encoder.encode(payload)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw PairingError.invalidResponse
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func makeLocalNetworkConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.waitsForConnectivity = true
        return config
    }

    private func savePairedDevice(_ device: PairedCaneDevice) {
        pairedDevice = device
        if let data = try? encoder.encode(device) {
            UserDefaults.standard.set(data, forKey: pairingStorageKey)
        }
    }

    private static func loadPairedDevice(storageKey: String) -> PairedCaneDevice? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(PairedCaneDevice.self, from: data)
    }

    private func connectionCandidates() -> [EndpointProfile] {
        var candidates: [EndpointProfile] = []
        var seenHosts = Set<String>()

        func appendCandidate(_ endpoint: EndpointProfile) {
            let normalizedHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedHost.isEmpty, !seenHosts.contains(normalizedHost) else {
                return
            }
            seenHosts.insert(normalizedHost)
            candidates.append(endpoint)
        }

        if let pairedDevice {
            appendCandidate(
                EndpointProfile(
                    host: pairedDevice.host,
                    port: pairedDevice.port,
                    path: pairedDevice.wsPath ?? runtimePath,
                    label: pairedDevice.deviceName
                )
            )
        }

        appendCandidate(
            EndpointProfile(
                host: mdnsRuntimeHost,
                port: runtimePort,
                path: runtimePath,
                label: pairedDevice?.deviceName ?? "SmartCane"
            )
        )

        return candidates
    }

    private func discoverBonjourEndpoint(excluding hosts: [String]) async -> EndpointProfile? {
        let excludedHosts = Set(hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return await withCheckedContinuation { continuation in
            let lookup = BonjourLookup(serviceType: bonjourServiceType, timeout: 2.5) { [weak self] result in
                Task { @MainActor in
                    self?.activeBonjourLookup = nil
                    guard let result else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let normalizedHost = result.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !excludedHosts.contains(normalizedHost) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    self?.updateDiscoveredRuntimeHost(
                        host: result.host,
                        deviceName: result.deviceName,
                        wsPath: result.path
                    )
                    continuation.resume(
                        returning: EndpointProfile(
                            host: result.host,
                            port: String(result.port),
                            path: result.path,
                            label: result.deviceName
                        )
                    )
                }
            }
            activeBonjourLookup = lookup
            lookup.start()
        }
    }

    private static func disconnectedStatusMessage(for pairedDevice: PairedCaneDevice?) -> String {
        if let pairedDevice {
            return "Turn on Personal Hotspot. Last Pi endpoint: \(pairedDevice.host):\(pairedDevice.port)."
        }

        return "Turn on Personal Hotspot and keep BLE diagnostics open until the Pi reports an IP."
    }

    private func payloadTypeDescription(for data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else {
            return "unknown"
        }
        return type
    }

    private func makeWebSocketURL(for endpoint: EndpointProfile) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = endpoint.host
        components.port = Int(endpoint.port)
        components.path = Self.normalizedPath(endpoint.path, fallback: "/ws")
        return components.url
    }

    private nonisolated static func normalizedPath(_ path: String?, fallback: String) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return fallback
        }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func appendDebugLog(_ subsystem: String, _ message: String) {
        debugLogEntries.insert(DebugLogEntry(subsystem: subsystem, message: message), at: 0)
        if debugLogEntries.count > 200 {
            debugLogEntries.removeLast(debugLogEntries.count - 200)
        }
    }
}

private final class BonjourLookup: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Result {
        let host: String
        let port: Int
        let path: String
        let deviceName: String
    }

    private let browser = NetServiceBrowser()
    private let serviceType: String
    private let timeout: TimeInterval
    private let completion: (Result?) -> Void
    private var didFinish = false
    private var timeoutWork: DispatchWorkItem?
    private var trackedServices: [NetService] = []

    init(serviceType: String, timeout: TimeInterval, completion: @escaping (Result?) -> Void) {
        self.serviceType = serviceType
        self.timeout = timeout
        self.completion = completion
        super.init()
    }

    func start() {
        browser.delegate = self
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        self.timeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        trackedServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: timeout)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.addresses?.compactMap(Self.hostString(from:)).first ?? Self.normalizedHostName(sender.hostName),
              !host.isEmpty else {
            return
        }

        let txt = sender.txtRecordData().flatMap(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let path = txt["path"].flatMap { String(data: $0, encoding: .utf8) } ?? "/ws"
        let deviceName = txt["deviceName"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        finish(Result(host: host, port: sender.port, path: path, deviceName: deviceName))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        if trackedServices.allSatisfy({ $0 !== sender && $0.hostName == nil && ($0.addresses?.isEmpty ?? true) }) {
            finish(nil)
        }
    }

    private func finish(_ result: Result?) {
        guard !didFinish else {
            return
        }
        didFinish = true
        timeoutWork?.cancel()
        browser.stop()
        trackedServices.forEach { $0.stop() }
        trackedServices.removeAll()
        completion(result)
    }

    private static func normalizedHostName(_ hostName: String?) -> String? {
        guard let hostName else {
            return nil
        }
        return hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func hostString(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return nil
            }

            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(data.count)
            let result = getnameinfo(
                sockaddrPointer,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                return nil
            }
            return String(cString: hostBuffer)
        }
    }
}
