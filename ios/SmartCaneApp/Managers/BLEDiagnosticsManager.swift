import CoreBluetooth
import Foundation

struct BLEDiagnosticDevice: Identifiable, Hashable {
    struct ParsedStatus: Hashable {
        let modeDescription: String?
        let runtimeActive: Bool?
        let wifiClientActive: Bool?
        let clientConnected: Bool?
        let runtimeIP: String?
        let stageDescription: String?
        let errorDescription: String?
        let recentEvents: [String]
        let rawStatusPage: String?
        let rawHistoryPage: String?
    }

    let id: UUID
    let name: String
    let rssi: Int
    let lastSeen: Date
    let parsedStatus: ParsedStatus?

    var lastSeenLabel: String {
        let elapsed = Int(Date().timeIntervalSince(lastSeen))
        return elapsed <= 1 ? "just now" : "\(elapsed)s ago"
    }
}

@MainActor
final class BLEDiagnosticsManager: NSObject, ObservableObject {
    struct ProvisioningStatusSummary: Hashable {
        let phase: String
        let message: String
        let deviceID: String?
        let deviceName: String?
        let primaryHotspotSSID: String?
        let fallbackHotspotSSID: String?
        let configuredNetworks: [String]
        let connectedSSID: String?
        let lastConnectedSSID: String?
        let lastAttemptedSSID: String?
        let lastFailureReason: String?
        let missingPackages: [String]
        let recentMessages: [String]
        let runtimeIP: String?
    }

    private enum ActiveSessionMode {
        case provisioning
        case diagnostics
    }

    private struct TrackedDevice {
        let id: UUID
        var peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var lastSeen: Date
        var statusPage: String?
        var historyPage: String?
    }

    @Published private(set) var bluetoothStateSummary = "Bluetooth diagnostics idle"
    @Published private(set) var isScanning = false
    @Published private(set) var nearbyDevices: [BLEDiagnosticDevice] = []
    @Published private(set) var provisioningStateSummary = "BLE provisioning idle"
    @Published private(set) var latestProvisioningStatusPayload = ""
    @Published private(set) var latestProvisioningStatusSummary: ProvisioningStatusSummary?
    @Published private(set) var isProvisioning = false
    @Published private(set) var isReadingDetailedStatus = false
    @Published var hotspotSSIDDraft = ""
    @Published var hotspotPasswordDraft = ""

    private var centralManager: CBCentralManager!
    private weak var connectionManager: CaneConnectionManager?
    private let hotspotCredentialsStore = HotspotCredentialsStore()
    private var shouldResumeScan = false
    private var trackedDevices: [UUID: TrackedDevice] = [:]
    private let provisioningServiceUUID = CBUUID(string: "7D0D1000-6A6E-4B2D-9B5F-8F5F7F51A001")
    private let credentialsCharacteristicUUID = CBUUID(string: "7D0D1001-6A6E-4B2D-9B5F-8F5F7F51A001")
    private let statusCharacteristicUUID = CBUUID(string: "7D0D1002-6A6E-4B2D-9B5F-8F5F7F51A001")
    private var connectedProvisioningPeripheral: CBPeripheral?
    private var credentialsCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var pendingProvisionPayload: Data?
    private var statusPollTask: Task<Void, Never>?
    private var activeSessionMode: ActiveSessionMode?
    private var shouldAutoConnectWhenRuntimeReady = false
    private var hasAttemptedAutoConnectAfterHotspotJoin = false
    private var hasAutoProvisionedSavedCredentialsThisSession = false

    init(connectionManager: CaneConnectionManager? = nil) {
        self.connectionManager = connectionManager
        super.init()
        if let credentials = savedOrDraftCredentials() {
            hotspotSSIDDraft = credentials.ssid
            hotspotPasswordDraft = credentials.password
        }
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        shouldResumeScan = true
        guard centralManager.state == .poweredOn else {
            bluetoothStateSummary = Self.summary(for: centralManager.state)
            return
        }
        guard !isScanning else {
            return
        }

        trackedDevices = [:]
        nearbyDevices = []
        bluetoothStateSummary = "Scanning for SmartCane BLE service"
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: [provisioningServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func beginConnectionAssist(autoConnect: Bool = true) {
        shouldAutoConnectWhenRuntimeReady = autoConnect
        hasAttemptedAutoConnectAfterHotspotJoin = false
        hasAutoProvisionedSavedCredentialsThisSession = false
        startScanning()
        if autoConnect, hasSavedHotspotCredentials {
            provisioningStateSummary = "Searching for the Pi over BLE. Saved hotspot details are ready if the Pi asks for them."
        } else {
            provisioningStateSummary = "Searching for the Pi over BLE"
        }

        if !nearbyDevices.isEmpty,
           !isReadingDetailedStatus,
           !isProvisioning {
            readDetailedDiagnostics()
        }
    }

    func endConnectionAssist() {
        shouldAutoConnectWhenRuntimeReady = false
        hasAttemptedAutoConnectAfterHotspotJoin = false
        hasAutoProvisionedSavedCredentialsThisSession = false
    }

    func stopScanning() {
        shouldResumeScan = false
        guard isScanning else {
            return
        }
        centralManager.stopScan()
        isScanning = false
        bluetoothStateSummary = "Bluetooth diagnostics stopped"
    }

    private func upsertDevice(name: String, peripheral: CBPeripheral, rssi: NSNumber) {
        var tracked = trackedDevices[peripheral.identifier] ?? TrackedDevice(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: "SmartCane BLE",
            rssi: rssi.intValue,
            lastSeen: Date(),
            statusPage: nil,
            historyPage: nil
        )

        tracked.peripheral = peripheral
        tracked.rssi = rssi.intValue
        tracked.lastSeen = Date()
        if name.hasPrefix("SC0") {
            tracked.statusPage = name
            tracked.name = "SmartCane BLE"
        } else if name.hasPrefix("SC1") {
            tracked.historyPage = name
            tracked.name = "SmartCane BLE"
        } else {
            tracked.name = name.isEmpty ? "SmartCane BLE" : name
        }

        trackedDevices[peripheral.identifier] = tracked
        nearbyDevices = trackedDevices.values
            .map(Self.device(from:))
            .sorted { lhs, rhs in
                lhs.lastSeen > rhs.lastSeen
            }

        if let parsedStatus = Self.parseStatus(statusPage: tracked.statusPage, historyPage: tracked.historyPage),
           parsedStatus.runtimeActive == true,
           parsedStatus.wifiClientActive == true,
           let runtimeIP = parsedStatus.runtimeIP {
            connectionManager?.updateDiscoveredRuntimeHost(host: runtimeIP)
            attemptAutoConnectIfNeeded(runtimeIP: runtimeIP)
        }

        bluetoothStateSummary = "Found \(nearbyDevices.count) SmartCane BLE beacon(s)"
    }

    func provisionHotspot(ssid: String, password: String) {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSSID.isEmpty, !trimmedPassword.isEmpty else {
            provisioningStateSummary = "Enter both hotspot name and password"
            return
        }

        hotspotSSIDDraft = trimmedSSID
        hotspotPasswordDraft = trimmedPassword
        hotspotCredentialsStore.save(ssid: trimmedSSID, password: trimmedPassword)

        guard let target = trackedDevices.values.sorted(by: { $0.lastSeen > $1.lastSeen }).first else {
            provisioningStateSummary = "No SmartCane BLE device found for provisioning"
            return
        }

        guard let payload = try? JSONSerialization.data(
            withJSONObject: [
                "hotspotSSID": trimmedSSID,
                "hotspotPassword": trimmedPassword,
            ]
        ) else {
            provisioningStateSummary = "Failed to encode hotspot credentials"
            return
        }

        pendingProvisionPayload = payload
        activeSessionMode = .provisioning
        hasAttemptedAutoConnectAfterHotspotJoin = false
        hasAutoProvisionedSavedCredentialsThisSession = true
        connectedProvisioningPeripheral = target.peripheral
        credentialsCharacteristic = nil
        statusCharacteristic = nil
        statusPollTask?.cancel()
        isProvisioning = true
        isReadingDetailedStatus = false
        provisioningStateSummary = "Connecting to \(target.name) for BLE provisioning"
        latestProvisioningStatusPayload = ""
        latestProvisioningStatusSummary = nil

        target.peripheral.delegate = self
        if target.peripheral.state == .connected {
            target.peripheral.discoverServices([provisioningServiceUUID])
        } else {
            centralManager.connect(target.peripheral)
        }
    }

    func readDetailedDiagnostics() {
        guard let target = trackedDevices.values.sorted(by: { $0.lastSeen > $1.lastSeen }).first else {
            provisioningStateSummary = "No SmartCane BLE device found for diagnostics"
            return
        }

        pendingProvisionPayload = nil
        activeSessionMode = .diagnostics
        connectedProvisioningPeripheral = target.peripheral
        credentialsCharacteristic = nil
        statusCharacteristic = nil
        statusPollTask?.cancel()
        isProvisioning = false
        isReadingDetailedStatus = true
        provisioningStateSummary = "Connecting to \(target.name) for detailed BLE diagnostics"
        latestProvisioningStatusSummary = nil

        target.peripheral.delegate = self
        if target.peripheral.state == .connected {
            target.peripheral.discoverServices([provisioningServiceUUID])
        } else {
            centralManager.connect(target.peripheral)
        }
    }

    private static func device(from tracked: TrackedDevice) -> BLEDiagnosticDevice {
        let parsedStatus = parseStatus(statusPage: tracked.statusPage, historyPage: tracked.historyPage)
        return BLEDiagnosticDevice(
            id: tracked.id,
            name: tracked.name,
            rssi: tracked.rssi,
            lastSeen: tracked.lastSeen,
            parsedStatus: parsedStatus
        )
    }

    private static func summary(for state: CBManagerState) -> String {
        switch state {
        case .unknown:
            return "Bluetooth state unknown"
        case .resetting:
            return "Bluetooth is resetting"
        case .unsupported:
            return "Bluetooth LE is unsupported on this device"
        case .unauthorized:
            return "Bluetooth permission denied"
        case .poweredOff:
            return "Turn Bluetooth on to scan for Pi diagnostics"
        case .poweredOn:
            return "Bluetooth ready"
        @unknown default:
            return "Bluetooth state unavailable"
        }
    }

    private static func parseStatus(statusPage: String?, historyPage: String?) -> BLEDiagnosticDevice.ParsedStatus? {
        var modeDescription: String?
        var runtimeActive: Bool?
        var wifiClientActive: Bool?
        var clientConnected: Bool?
        var runtimeIP: String?
        var stageDescription: String?
        var errorDescription: String?
        var recentEvents: [String] = []

        if let statusPage, statusPage.hasPrefix("SC0") {
            let tokens = statusPage.dropFirst(3)
            if let modeCode = singleCharacter(after: "M", in: tokens) {
                modeDescription = modeText(for: modeCode)
            }
            runtimeActive = value(after: "R", in: tokens)
            wifiClientActive = value(after: "W", in: tokens)
            clientConnected = value(after: "C", in: tokens)

            if let stageCode = code(after: "P", in: tokens) {
                stageDescription = stageText(for: stageCode)
            }
            if let errorCode = code(after: "E", in: tokens) {
                errorDescription = errorText(for: errorCode)
            }
            if let ipHex = rawValue(after: "I", length: 8, in: tokens) {
                runtimeIP = ipv4(fromHex: ipHex)
            }
        }

        if let historyPage, historyPage.hasPrefix("SC1") {
            let rawCodes = Array(historyPage.dropFirst(3))
            stride(from: 0, to: rawCodes.count, by: 2).forEach { index in
                guard index + 1 < rawCodes.count else {
                    return
                }
                let code = String(rawCodes[index]) + String(rawCodes[index + 1])
                recentEvents.append(stageText(for: code))
            }
        }

        if modeDescription == nil,
           runtimeActive == nil,
           wifiClientActive == nil,
           clientConnected == nil,
           runtimeIP == nil,
           stageDescription == nil,
           errorDescription == nil,
           recentEvents.isEmpty,
           statusPage == nil,
           historyPage == nil {
            return nil
        }

        return BLEDiagnosticDevice.ParsedStatus(
            modeDescription: modeDescription,
            runtimeActive: runtimeActive,
            wifiClientActive: wifiClientActive,
            clientConnected: clientConnected,
            runtimeIP: runtimeIP,
            stageDescription: stageDescription,
            errorDescription: errorDescription,
            recentEvents: recentEvents,
            rawStatusPage: statusPage,
            rawHistoryPage: historyPage
        )
    }

    private static func value(after prefix: Character, in tokens: Substring) -> Bool? {
        guard let index = tokens.firstIndex(of: prefix),
              let nextIndex = tokens.index(index, offsetBy: 1, limitedBy: tokens.endIndex),
              nextIndex < tokens.endIndex else {
            return nil
        }
        return tokens[nextIndex] == "1"
    }

    private static func singleCharacter(after prefix: Character, in tokens: Substring) -> String? {
        rawValue(after: prefix, length: 1, in: tokens)
    }

    private static func code(after prefix: Character, in tokens: Substring) -> String? {
        rawValue(after: prefix, length: 2, in: tokens)
    }

    private static func rawValue(after prefix: Character, length: Int, in tokens: Substring) -> String? {
        guard let index = tokens.firstIndex(of: prefix),
              let start = tokens.index(index, offsetBy: 1, limitedBy: tokens.endIndex) else {
            return nil
        }

        guard let end = tokens.index(start, offsetBy: length, limitedBy: tokens.endIndex) else {
            return nil
        }

        return String(tokens[start..<end])
    }

    private static func modeText(for code: String) -> String {
        switch code {
        case "H":
            return "Phone hotspot client"
        case "A":
            return "Pi access point"
        case "N":
            return "Network not configured"
        default:
            return code
        }
    }

    private static func ipv4(fromHex value: String) -> String? {
        guard value.count == 8, value != "00000000" else {
            return nil
        }

        var octets: [String] = []
        var index = value.startIndex
        while index < value.endIndex {
            let nextIndex = value.index(index, offsetBy: 2)
            let chunk = value[index..<nextIndex]
            guard let number = UInt8(chunk, radix: 16) else {
                return nil
            }
            octets.append(String(number))
            index = nextIndex
        }
        return octets.joined(separator: ".")
    }

    private static func stageText(for code: String) -> String {
        switch code {
        case "BO":
            return "Booting"
        case "PV":
            return "Waiting for BLE provisioning"
        case "PS":
            return "Provisioning credentials saved"
        case "PJ":
            return "Joining hotspot"
        case "NR":
            return "Network ready"
        case "WL":
            return "WebSocket listening"
        case "AC":
            return "App TCP/WebSocket connected"
        case "PW":
            return "Waiting for PAIR_HELLO timed out"
        case "PR":
            return "PAIR_HELLO received"
        case "PT":
            return "PAIR_INFO sent"
        case "HB":
            return "Heartbeat received"
        case "CM":
            return "Command received"
        case "DP":
            return "Debug ping handled"
        case "CF":
            return "AP test confirmed"
        case "DC":
            return "Client disconnected"
        case "SD":
            return "Runtime shutting down"
        case "NO":
            return "No event"
        default:
            return code
        }
    }

    private static func errorText(for code: String) -> String {
        switch code {
        case "NO":
            return "No error"
        case "BP":
            return "BLE provisioning service unavailable"
        case "BJ":
            return "BLE credentials JSON invalid"
        case "BC":
            return "BLE credentials missing fields"
        case "HC":
            return "Hotspot join failed"
        case "WT":
            return "Client connected but never sent PAIR_HELLO"
        case "JM":
            return "Malformed JSON from app"
        case "NS":
            return "AP confirm script missing"
        case "RC":
            return "AP confirm command failed"
        case "EX":
            return "AP confirm raised exception"
        case "NF":
            return "Network not ready"
        case "HT":
            return "Heartbeat timeout"
        case "UF":
            return "Ultrasonic fault"
        case "GU":
            return "GPS unavailable"
        case "IU":
            return "IMU unavailable"
        case "HI":
            return "Handle IMU unavailable"
        case "MI":
            return "Motor IMU unavailable"
        case "MD":
            return "Motor driver fault"
        case "XX":
            return "Unknown error"
        default:
            return code
        }
    }
}

extension BLEDiagnosticsManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.bluetoothStateSummary = Self.summary(for: central.state)

            guard central.state == .poweredOn else {
                if self.isScanning {
                    self.centralManager.stopScan()
                    self.isScanning = false
                }
                return
            }

            if self.shouldResumeScan {
                self.startScanning()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let resolvedName = localName ?? peripheral.name ?? "SmartCane BLE"

        Task { @MainActor in
            self.upsertDevice(name: resolvedName, peripheral: peripheral, rssi: RSSI)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.provisioningStateSummary = self.activeSessionMode == .diagnostics
                ? "BLE connected. Reading SmartCane diagnostics service"
                : "BLE connected. Discovering SmartCane provisioning service"
            self.connectedProvisioningPeripheral = peripheral
            peripheral.delegate = self
            peripheral.discoverServices([self.provisioningServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isProvisioning = false
            self.isReadingDetailedStatus = false
            self.provisioningStateSummary = "BLE connect failed: \(error?.localizedDescription ?? "Unknown error")"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if self.connectedProvisioningPeripheral?.identifier == peripheral.identifier {
                self.connectedProvisioningPeripheral = nil
                self.credentialsCharacteristic = nil
                self.statusCharacteristic = nil
                self.statusPollTask?.cancel()
                self.activeSessionMode = nil
                if self.isProvisioning {
                    self.provisioningStateSummary = "BLE provisioning disconnected"
                    self.isProvisioning = false
                }
                if self.isReadingDetailedStatus {
                    self.provisioningStateSummary = "BLE diagnostics disconnected"
                    self.isReadingDetailedStatus = false
                }
            }
        }
    }
}

extension BLEDiagnosticsManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.provisioningStateSummary = "BLE service discovery failed: \(error.localizedDescription)"
                self.isProvisioning = false
                return
            }

            guard let service = peripheral.services?.first(where: { $0.uuid == self.provisioningServiceUUID }) else {
                self.provisioningStateSummary = "SmartCane BLE service not found"
                self.isProvisioning = false
                self.isReadingDetailedStatus = false
                return
            }

            self.provisioningStateSummary = self.activeSessionMode == .diagnostics
                ? "Diagnostics service found. Discovering characteristics"
                : "Provisioning service found. Discovering characteristics"
            peripheral.discoverCharacteristics([self.credentialsCharacteristicUUID, self.statusCharacteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                self.provisioningStateSummary = "BLE characteristic discovery failed: \(error.localizedDescription)"
                self.isProvisioning = false
                self.isReadingDetailedStatus = false
                return
            }

            self.credentialsCharacteristic = service.characteristics?.first(where: { $0.uuid == self.credentialsCharacteristicUUID })
            self.statusCharacteristic = service.characteristics?.first(where: { $0.uuid == self.statusCharacteristicUUID })

            guard let credentialsCharacteristic = self.credentialsCharacteristic else {
                self.provisioningStateSummary = "Credentials characteristic not found"
                self.isProvisioning = false
                self.isReadingDetailedStatus = false
                return
            }

            if let payload = self.pendingProvisionPayload {
                self.provisioningStateSummary = "Sending hotspot credentials over BLE"
                peripheral.writeValue(payload, for: credentialsCharacteristic, type: .withResponse)
            } else {
                self.provisioningStateSummary = "Reading detailed BLE diagnostics"
                self.scheduleProvisionStatusPolling(iterations: 3)
            }

            if let statusCharacteristic = self.statusCharacteristic {
                peripheral.readValue(for: statusCharacteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                self.provisioningStateSummary = "BLE write failed: \(error.localizedDescription)"
                self.isProvisioning = false
                self.isReadingDetailedStatus = false
                return
            }

            self.provisioningStateSummary = "Hotspot credentials sent. Waiting for Pi provisioning status"
            self.scheduleProvisionStatusPolling(iterations: 8)
            if let statusCharacteristic = self.statusCharacteristic {
                peripheral.readValue(for: statusCharacteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                self.provisioningStateSummary = "BLE status read failed: \(error.localizedDescription)"
                return
            }

            guard characteristic.uuid == self.statusCharacteristicUUID,
                  let data = characteristic.value else {
                return
            }

            self.handleProvisioningStatusPayload(data)
        }
    }
}

private extension BLEDiagnosticsManager {
    func scheduleProvisionStatusPolling(iterations: Int) {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            for _ in 0..<iterations {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self,
                      !Task.isCancelled,
                      let peripheral = self.connectedProvisioningPeripheral,
                      let statusCharacteristic = self.statusCharacteristic else {
                    return
                }

                peripheral.readValue(for: statusCharacteristic)
            }

            await MainActor.run {
                self?.isProvisioning = false
                self?.isReadingDetailedStatus = false
                self?.activeSessionMode = nil
            }
        }
    }

    func handleProvisioningStatusPayload(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        latestProvisioningStatusPayload = text

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            provisioningStateSummary = "Provisioning status: \(text)"
            latestProvisioningStatusSummary = nil
            return
        }

        let phase = payload["phase"] as? String ?? "UNKNOWN"
        let message = payload["message"] as? String ?? "No message"
        let runtimeIP = nonEmptyString(payload["runtimeIP"])
        let deviceID = nonEmptyString(payload["deviceID"])
        let deviceName = nonEmptyString(payload["deviceName"])
        let connectedSSID = nonEmptyString(payload["connectedSSID"])
        let willReuseSavedCredentials = shouldAutoReuseSavedCredentials(
            phase: phase,
            connectedSSID: connectedSSID
        )

        if willReuseSavedCredentials {
            provisioningStateSummary = "Pi is waiting for hotspot details. Reusing the saved hotspot credentials now."
        } else {
            provisioningStateSummary = "\(phase): \(message)"
        }

        connectionManager?.updateBLEProvisioningStatus(
            phase: phase,
            message: message,
            connectedSSID: connectedSSID,
            runtimeIP: runtimeIP,
            usingSavedCredentials: willReuseSavedCredentials
        )

        maybeAutoProvisionSavedCredentials(
            phase: phase,
            connectedSSID: connectedSSID
        )

        if let runtimeIP {
            connectionManager?.updateDiscoveredRuntimeHost(host: runtimeIP, deviceName: deviceName, deviceID: deviceID)
            attemptAutoConnectIfNeeded(runtimeIP: runtimeIP)
        }

        latestProvisioningStatusSummary = ProvisioningStatusSummary(
            phase: phase,
            message: message,
            deviceID: deviceID,
            deviceName: deviceName,
            primaryHotspotSSID: nonEmptyString(payload["hotspotSSID"]),
            fallbackHotspotSSID: nonEmptyString(payload["fallbackHotspotSSID"]),
            configuredNetworks: stringArray(payload["configuredNetworks"]),
            connectedSSID: connectedSSID,
            lastConnectedSSID: nonEmptyString(payload["lastConnectedSSID"]),
            lastAttemptedSSID: nonEmptyString(payload["lastAttemptedSSID"]),
            lastFailureReason: nonEmptyString(payload["lastFailureReason"]),
            missingPackages: stringArray(payload["missingPackages"]),
            recentMessages: stringArray(payload["recentMessages"]),
            runtimeIP: runtimeIP
        )

        if phase == "HOTSPOT_CONNECTED" {
            attemptAutoConnectAfterHotspotJoin()
            isProvisioning = true
            if runtimeIP == nil {
                provisioningStateSummary = "HOTSPOT_CONNECTED: Joined hotspot. Waiting for runtime IP"
            } else {
                provisioningStateSummary = "HOTSPOT_CONNECTED: Joined hotspot. Waiting for Pi runtime to accept connections"
            }
            scheduleProvisionStatusPolling(iterations: 12)
        }
    }

    func attemptAutoConnectIfNeeded(runtimeIP: String) {
        guard shouldAutoConnectWhenRuntimeReady,
              !runtimeIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        hasAttemptedAutoConnectAfterHotspotJoin = true
        if connectionManager?.connectToCane() == true {
            provisioningStateSummary = "Pi reported runtime IP \(runtimeIP). Connecting over Wi-Fi now."
        }
    }

    func attemptAutoConnectAfterHotspotJoin() {
        guard shouldAutoConnectWhenRuntimeReady,
              !hasAttemptedAutoConnectAfterHotspotJoin else {
            return
        }

        hasAttemptedAutoConnectAfterHotspotJoin = true
        if connectionManager?.connectToCane() == true {
            provisioningStateSummary = "Pi joined the hotspot. Trying the saved runtime endpoint and Bonjour now."
        }
    }

    func maybeAutoProvisionSavedCredentials(phase: String, connectedSSID: String?) {
        guard shouldAutoConnectWhenRuntimeReady,
              !hasAutoProvisionedSavedCredentialsThisSession,
              connectedSSID == nil else {
            return
        }

        let waitingForProvisioning = phase == "BLE_READY" || phase == "WAITING_FOR_HOTSPOT" || phase == "INVALID_PAYLOAD"
        guard waitingForProvisioning,
              let credentials = savedOrDraftCredentials() else {
            return
        }

        hasAutoProvisionedSavedCredentialsThisSession = true
        provisioningStateSummary = "Pi is waiting for hotspot details. Reusing saved hotspot credentials."
        provisionHotspot(ssid: credentials.ssid, password: credentials.password)
    }

    var hasSavedHotspotCredentials: Bool {
        savedOrDraftCredentials() != nil
    }

    func shouldAutoReuseSavedCredentials(phase: String, connectedSSID: String?) -> Bool {
        guard shouldAutoConnectWhenRuntimeReady,
              !hasAutoProvisionedSavedCredentialsThisSession,
              connectedSSID == nil else {
            return false
        }

        let waitingForProvisioning = phase == "BLE_READY" || phase == "WAITING_FOR_HOTSPOT" || phase == "INVALID_PAYLOAD"
        return waitingForProvisioning && hasSavedHotspotCredentials
    }

    func savedOrDraftCredentials() -> HotspotCredentials? {
        if let credentials = hotspotCredentialsStore.load(),
           !credentials.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return credentials
        }

        let trimmedSSID = hotspotSSIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = hotspotPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty, !trimmedPassword.isEmpty else {
            return nil
        }
        return HotspotCredentials(ssid: trimmedSSID, password: trimmedPassword)
    }

    func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func stringArray(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else {
            return []
        }
        return items.compactMap { item in
            guard let string = item as? String else {
                return nil
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
