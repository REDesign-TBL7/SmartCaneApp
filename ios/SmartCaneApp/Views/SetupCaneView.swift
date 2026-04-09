/*
 File: SetupCaneView.swift
 Purpose:
 First-time onboarding screen for a new cane.
*/

import SwiftUI

struct SetupCaneView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var setupManager: CaneSetupManager
    @EnvironmentObject private var speechManager: SpeechManager

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Turn on your iPhone Personal Hotspot first. Then open iPhone Wi-Fi settings, join SmartCaneSetup using password SmartCaneSetup123, return to this screen, and send the hotspot details to the cane.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Hotspot") {
                    TextField("Hotspot name", text: $setupManager.hotspotSSID)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .accessibilityLabel("Hotspot name")
                        .accessibilityHint("The name of your iPhone hotspot network.")

                    SecureField("Hotspot password", text: $setupManager.hotspotPassword)
                        .textContentType(.password)
                        .accessibilityLabel("Hotspot password")
                        .accessibilityHint("The password for your iPhone hotspot.")
                }

                Section("Device") {
                    TextField("Cane name", text: $setupManager.desiredDeviceName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .accessibilityLabel("Cane name")
                        .accessibilityHint("An optional name for this cane.")

                    Text(setupManager.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let lastErrorMessage = setupManager.lastErrorMessage {
                        Text(lastErrorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Button {
                        Task {
                            let success = await setupManager.provisionCane(connectionManager: connectionManager)
                            if success {
                                speechManager.speak("Cane setup sent. Waiting for the cane to join your hotspot.", interrupt: true)
                                dismiss()
                            } else if let error = setupManager.lastErrorMessage {
                                speechManager.speak("Cane setup failed. \(error)", interrupt: true)
                            }
                        }
                    } label: {
                        HStack {
                            if setupManager.isProvisioning {
                                ProgressView()
                            }
                            Text(setupManager.isProvisioning ? "Setting up cane" : "Set up cane")
                        }
                    }
                    .disabled(setupManager.isProvisioning)
                    .accessibilityLabel("Set up cane")
                    .accessibilityHint("Sends your hotspot details to the cane after you have joined the setup Wi-Fi in iPhone settings.")
                }
            }
            .navigationTitle("Set Up Cane")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await setupManager.refreshSetupStatus()
            }
        }
    }
}
