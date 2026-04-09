/*
 File: CaneSetupManager.swift
 Purpose:
 This file handles first-time Wi-Fi onboarding for a new cane.

 Flow:
 1. User joins the cane's temporary setup Wi-Fi network in iPhone Settings.
 2. App sends the phone hotspot credentials to the Pi setup server.
 3. Pi switches to hotspot-client mode.
 4. App returns to the normal hotspot pairing flow.
*/

import Foundation
import UIKit

@MainActor
final class CaneSetupManager: ObservableObject {
    @Published var hotspotSSID: String
    @Published var hotspotPassword = ""
    @Published var desiredDeviceName = ""
    @Published var isProvisioning = false
    @Published var statusMessage = "Set up a new cane"
    @Published var lastErrorMessage: String?

    let setupSSID = "SmartCaneSetup"
    let setupPassphrase = "SmartCaneSetup123"

    private struct SetupEndpoint {
        let host: String
        let port: String
        let label: String
    }

    private final class SetupBonjourDiscoverySession: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
        private let browser = NetServiceBrowser()
        private var services: [NetService] = []
        private var discoveredEndpoints: [SetupEndpoint] = []
        private var continuation: CheckedContinuation<[SetupEndpoint], Never>?
        private var timeoutWorkItem: DispatchWorkItem?

        func discover(timeout: TimeInterval, continuation: CheckedContinuation<[SetupEndpoint], Never>) {
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_smartcane-setup._tcp.", inDomain: "local.")

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

            discoveredEndpoints.append(
                SetupEndpoint(
                    host: hostName,
                    port: String(sender.port),
                    label: sender.name
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
            continuation.resume(returning: discoveredEndpoints)
            discoveredEndpoints = []
        }
    }

    private var bonjourDiscoverySession: SetupBonjourDiscoverySession?

    init() {
        hotspotSSID = UIDevice.current.name
    }

    func refreshSetupStatus() async {
        do {
            guard let setupStatusEndpoint = await resolvedSetupStatusURL() else {
                return
            }

            let (data, _) = try await localOnlySession().data(from: setupStatusEndpoint)
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deviceName = payload["deviceName"] as? String {
                if desiredDeviceName.isEmpty {
                    desiredDeviceName = deviceName
                }
                statusMessage = "Found \(deviceName) in setup mode"
            }
        } catch {
            // Setup AP may not be joined yet. Keep quiet.
        }
    }

    func provisionCane(connectionManager: CaneConnectionManager) async -> Bool {
        let trimmedSSID = hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = hotspotPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = desiredDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSSID.isEmpty, !trimmedPassword.isEmpty else {
            lastErrorMessage = "Enter your hotspot name and password first."
            return false
        }

        isProvisioning = true
        lastErrorMessage = nil
        defer {
            isProvisioning = false
        }

        do {
            statusMessage = "Sending hotspot details to cane"
            try await sendSetupRequest(
                hotspotSSID: trimmedSSID,
                hotspotPassword: trimmedPassword,
                deviceName: trimmedDeviceName
            )

            statusMessage = "Cane is switching to your hotspot"
            try? await Task.sleep(nanoseconds: 8_000_000_000)

            connectionManager.forgetPairedCane()
            connectionManager.connectToCane()
            statusMessage = "Trying hotspot connection"
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = "Setup failed"
            return false
        }
    }

    private func sendSetupRequest(hotspotSSID: String, hotspotPassword: String, deviceName: String) async throws {
        guard let setupEndpoint = await resolvedSetupRequestURL() else {
            throw URLError(.cannotFindHost)
        }

        var request = URLRequest(url: setupEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "hotspotSSID": hotspotSSID,
                "hotspotPassword": hotspotPassword,
                "deviceName": deviceName
            ]
        )

        let (_, response) = try await localOnlySession().data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func resolvedSetupStatusURL() async -> URL? {
        guard let endpoint = await discoverSetupEndpoint() else {
            return nil
        }

        return URL(string: "http://\(endpoint.host):\(endpoint.port)/setup/status")
    }

    private func resolvedSetupRequestURL() async -> URL? {
        guard let endpoint = await discoverSetupEndpoint() else {
            lastErrorMessage = "Could not find the cane setup service. Make sure your iPhone is joined to SmartCaneSetup."
            statusMessage = "Setup service not found"
            return nil
        }

        return URL(string: "http://\(endpoint.host):\(endpoint.port)/setup/hotspot")
    }

    private func discoverSetupEndpoint() async -> SetupEndpoint? {
        let discovered = await withCheckedContinuation { (continuation: CheckedContinuation<[SetupEndpoint], Never>) in
            let session = SetupBonjourDiscoverySession()
            bonjourDiscoverySession = session
            session.discover(timeout: 2.0, continuation: continuation)
        }

        bonjourDiscoverySession = nil
        return discovered.first
    }

    private func localOnlySession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }
}
