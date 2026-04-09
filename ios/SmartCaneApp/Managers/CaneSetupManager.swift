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
    private let setupEndpoint = URL(string: "http://192.168.4.1:8081/setup/hotspot")!
    private let setupStatusEndpoint = URL(string: "http://192.168.4.1:8081/setup/status")!

    init() {
        hotspotSSID = UIDevice.current.name
    }

    func refreshSetupStatus() async {
        do {
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

    private func localOnlySession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }
}
