import Foundation
import Network

@MainActor
final class CaneConnectionManager: ObservableObject {
    @Published var caneState = CaneState()
    @Published var debugLogEntries: [DebugLogEntry] = []
    @Published var lastPingRoundTripMs: Int?
    @Published private(set) var pairedDevice: PairedCaneDevice?
    @Published private(set) var isPairing = false

    private struct EndpointProfile {
        let host: String
        let port: String
        let label: String
    }

    private struct DiscoveredCaneService {
        let endpoint: EndpointProfile
        let deviceID: String?
        let deviceName: String?
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

    private final class BonjourDiscoverySession: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
        private let browser = NetServiceBrowser()
        private var services: [NetService] = []
        private var discoveredServices: [DiscoveredCaneService] = []
        private var continuation: CheckedContinuation<[DiscoveredCaneService], Never>?
        private var timeoutWorkItem: DispatchWorkItem?

        func discover(timeout: TimeInterval, continuation: CheckedContinuation<[DiscoveredCaneService], Never>) {
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_smartcane._tcp.", inDomain: "local.")

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish()
            }
            self.timeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 1.5)
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let hostName = sender.hostName?
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

            guard let hostName, !hostName.isEmpty, sender.port > 0 else {
                return
            }

            let txtRecord = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
            let deviceID = txtRecord["device_id"].flatMap { String(data: $0, encoding: .utf8) }
            let deviceName = txtRecord["device_name"].flatMap { String(data: $0, encoding: .utf8) }

            let endpoint = EndpointProfile(
                host: hostName,
                port: String(sender.port),
                label: deviceName ?? sender.name
            )
            discoveredServices.append(
                DiscoveredCaneService(
                    endpoint: endpoint,
                    deviceID: deviceID,
                    deviceName: deviceName
                )
            )
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
            _ = errorDict
        }

        func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
            finish()
        }

        func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
            _ = errorDict
            finish()
        }

        private func finish() {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            browser.stop()
            services.removeAll()

            guard let continuation else {
                return
            }

            self.continuation = nil
            continuation.resume(returning: discoveredServices)
            discoveredServices = []
        }
    }

    private enum PairingError: LocalizedError {
        case invalidURL
        case handshakeTimedOut
        case invalidResponse
        case missingDeviceInfo

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
            }
        }
    }

    private let hotspotLabel = "Phone hotspot"
    private let pairingStorageKey = "smart_cane_paired_device"

    private var currentEndpoint: EndpointProfile?
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
    private var bonjourDiscoverySession: BonjourDiscoverySession?

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "smartcane.path.monitor")
    private var isWiFiActive = false
    private var isCellularActive = false

    init() {
        pairedDevice = Self.loadPairedDevice(storageKey: pairingStorageKey)
        caneState.connectionStatus = .disconnected
        caneState.currentInstruction = "No active navigation"
        caneState.currentNavigationCommand = .stop
        caneState.obstacleMessage = "No obstacles detected"
        caneState.statusMessage = pairedDevice.map {
            "Paired with \($0.deviceName). Ready to connect over Wi-Fi."
        } ?? "No cane paired yet. Connect to pair over Wi-Fi."
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
        "Phone hotspot mode keeps cellular internet available while cane traffic stays local over Wi-Fi."
    }

    var activeEndpointLabel: String {
        pairedDevice?.deviceName ?? currentEndpoint?.label ?? hotspotLabel
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
            caneState.statusMessage = "Turn on iPhone hotspot and make sure the Pi joins it first."
            appendDebugLog("connection", "Connect blocked because Wi-Fi is not active")
            return
        }

        caneState.connectionStatus = .connecting
        connectTask = Task { [weak self] in
            guard let self else {
                return
            }

            if let pairedDevice {
                await self.connectUsingSavedPairing(pairedDevice)
            } else {
                await self.pairAndConnect()
            }
        }
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
        caneState.statusMessage = pairedDevice.map {
            "Disconnected from \($0.deviceName). Ready to reconnect."
        } ?? "Wi-Fi cane link closed"
        pendingPingStartedAt = nil
        lastPingRoundTripMs = nil
    }

    func forgetPairedCane() {
        if caneState.connectionStatus == .connected {
            disconnectFromCane()
        }

        pairedDevice = nil
        UserDefaults.standard.removeObject(forKey: pairingStorageKey)
        caneState.statusMessage = "Saved cane pairing removed."
        appendDebugLog("pairing", "Forgot saved cane pairing")
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

    private func connectUsingSavedPairing(_ pairedDevice: PairedCaneDevice) async {
        let discoveredEndpoint = await discoverEndpoint(matching: pairedDevice.deviceID)
        let endpoint = discoveredEndpoint ?? EndpointProfile(
            host: pairedDevice.host,
            port: pairedDevice.port,
            label: hotspotLabel
        )
        caneState.statusMessage = "Connecting to \(pairedDevice.deviceName)"
        appendDebugLog("pairing", "Using saved pairing for \(pairedDevice.summaryText)")

        if let discoveredEndpoint {
            appendDebugLog(
                "mdns",
                "Resolved \(pairedDevice.deviceName) to \(discoveredEndpoint.host):\(discoveredEndpoint.port) over Bonjour"
            )
            savePairedDevice(
                PairedCaneDevice(
                    deviceID: pairedDevice.deviceID,
                    deviceName: pairedDevice.deviceName,
                    host: discoveredEndpoint.host,
                    port: discoveredEndpoint.port,
                    pairedAt: pairedDevice.pairedAt
                )
            )
        } else {
            appendDebugLog("mdns", "Bonjour lookup did not find \(pairedDevice.deviceName), falling back to saved resolved host")
        }

        let reachable = await probeEndpoint(endpoint)
        if reachable {
            openWebSocket(to: endpoint)
            connectTask = nil
            return
        }

        appendDebugLog("pairing", "Saved pairing not reachable, retrying pairing handshake")
        await pairAndConnect()
    }

    private func pairAndConnect() async {
        isPairing = true
        defer {
            isPairing = false
            connectTask = nil
        }

        caneState.statusMessage = "Looking for cane on iPhone hotspot"
        appendDebugLog("pairing", "Starting Wi-Fi pairing handshake")

        let endpoints = await candidatePairingEndpoints()
        appendDebugLog("mdns", "Trying \(endpoints.count) candidate endpoint(s) for pairing")

        for endpoint in endpoints {
            do {
                let result = try await performPairingHandshake(to: endpoint)
                pairedDevice = result.pairedDevice
                savePairedDevice(result.pairedDevice)
                appendDebugLog("pairing", "Paired with \(result.pairedDevice.summaryText)")
                adoptOpenWebSocket(
                    session: result.session,
                    task: result.task,
                    endpoint: EndpointProfile(
                        host: result.pairedDevice.host,
                        port: result.pairedDevice.port,
                        label: endpoint.label
                    )
                )
                return
            } catch {
                appendDebugLog(
                    "pairing",
                    "Pairing failed at \(endpoint.host):\(endpoint.port): \(error.localizedDescription)"
                )
            }
        }

        caneState.connectionStatus = .disconnected
        caneState.statusMessage = "Could not pair with cane over Wi-Fi."
    }

    private func performPairingHandshake(
        to endpoint: EndpointProfile
    ) async throws -> (session: URLSession, task: URLSessionWebSocketTask, pairedDevice: PairedCaneDevice) {
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.port)/ws") else {
            throw PairingError.invalidURL
        }

        let session = URLSession(configuration: makeWiFiOnlyConfiguration())
        let task = session.webSocketTask(with: url)
        task.resume()

        appendDebugLog("pairing", "Opened pairing socket to \(url.absoluteString)")
        try await sendImmediately(.pairHello(clientName: "SmartCane iPhone"), on: task)
        appendDebugLog("pairing", "Sent PAIR_HELLO")

        let response = try await receivePairInfo(on: task)
        guard let deviceID = response.deviceID, !deviceID.isEmpty,
              let deviceName = response.deviceName, !deviceName.isEmpty else {
            throw PairingError.missingDeviceInfo
        }

        return (
            session,
            task,
            PairedCaneDevice(
                deviceID: deviceID,
                deviceName: deviceName,
                host: endpoint.host,
                port: endpoint.port,
                pairedAt: Date()
            )
        )
    }

    private func receivePairInfo(on task: URLSessionWebSocketTask) async throws -> InboundPairInfoMessage {
        let message = try await withTimeout(seconds: 3.0) {
            try await task.receive()
        }

        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw PairingError.invalidResponse
        }

        guard let response = try? decoder.decode(InboundPairInfoMessage.self, from: data),
              response.type == "PAIR_INFO" else {
            throw PairingError.invalidResponse
        }

        return response
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

    private func candidatePairingEndpoints() async -> [EndpointProfile] {
        let discovered = await discoverBonjourServices()
        return discovered.map(\.endpoint)
    }

    private func discoverEndpoint(matching deviceID: String) async -> EndpointProfile? {
        let discovered = await discoverBonjourServices()
        if let matched = discovered.first(where: { $0.deviceID == deviceID }) {
            return matched.endpoint
        }
        return nil
    }

    private func discoverBonjourServices() async -> [DiscoveredCaneService] {
        appendDebugLog("mdns", "Browsing for _smartcane._tcp on local network")

        let discovered = await withCheckedContinuation { (continuation: CheckedContinuation<[DiscoveredCaneService], Never>) in
            let session = BonjourDiscoverySession()
            bonjourDiscoverySession = session
            session.discover(timeout: 2.0, continuation: continuation)
        }

        bonjourDiscoverySession = nil

        if discovered.isEmpty {
            appendDebugLog("mdns", "Bonjour discovery found no cane services")
        } else {
            let summary = discovered
                .map { "\($0.deviceName ?? $0.endpoint.label)@\($0.endpoint.host):\($0.endpoint.port)" }
                .joined(separator: ", ")
            appendDebugLog("mdns", "Bonjour discovery found \(discovered.count) service(s): \(summary)")
        }

        return discovered
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
        let internetPath = isCellularActive ? "Cellular internet active" : "Cellular internet availability managed by iPhone"
        if let pairedDevice {
            return "Connected to \(pairedDevice.deviceName) over \(endpoint.label). Cane traffic stays on Wi-Fi only. \(internetPath)."
        }

        return "Connected via \(endpoint.label). Cane traffic stays on Wi-Fi only. \(internetPath)."
    }

    private func openWebSocket(to endpoint: EndpointProfile) {
        guard let url = URL(string: "ws://\(endpoint.host):\(endpoint.port)/ws") else {
            caneState.connectionStatus = .disconnected
            caneState.statusMessage = "Invalid cane endpoint URL"
            appendDebugLog("connection", "Invalid WebSocket URL for \(endpoint.host):\(endpoint.port)")
            return
        }

        let session = URLSession(configuration: makeWiFiOnlyConfiguration())
        let task = session.webSocketTask(with: url)
        task.resume()
        appendDebugLog("socket", "Opened WebSocket to \(url.absoluteString)")
        adoptOpenWebSocket(session: session, task: task, endpoint: endpoint)
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

    private func makeWiFiOnlyConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = false
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

    private func appendDebugLog(_ subsystem: String, _ message: String) {
        debugLogEntries.insert(DebugLogEntry(subsystem: subsystem, message: message), at: 0)
        if debugLogEntries.count > 200 {
            debugLogEntries.removeLast(debugLogEntries.count - 200)
        }
    }
}
