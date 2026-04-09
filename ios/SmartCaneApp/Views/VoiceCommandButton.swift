/*
 File: VoiceCommandButton.swift
 Purpose:
 This reusable floating button starts and stops push-to-speak voice commands.

 It is intentionally separate from the screens so voice control can be available
 without replacing typing or Apple's VoiceOver navigation. The user normally
 taps once, speaks, and the app auto-submits after a short pause.
*/

import SwiftUI

struct VoiceCommandButton: View {
    @EnvironmentObject private var voiceCommandManager: VoiceCommandManager
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var speechManager: SpeechManager

    var body: some View {
        Button {
            voiceCommandManager.toggleListening(
                connectionManager: connectionManager,
                locationManager: locationManager,
                speechManager: speechManager
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: voiceCommandManager.isListening ? "stop.fill" : "mic.fill")
                    .font(.headline.weight(.semibold))
                    .accessibilityHidden(true)

                Text(voiceCommandManager.isListening ? "Listening" : "Speak")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(buttonColor, in: Capsule())
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voiceCommandManager.isListening ? "Listening for voice command" : "Start voice command")
        .accessibilityHint(voiceCommandManager.isListening ? "Listening will stop automatically after you finish speaking. Double tap to cancel or submit now." : "Starts listening for one voice command.")
    }

    private var buttonColor: Color {
        voiceCommandManager.isListening
            ? Color(red: 0.72, green: 0.18, blue: 0.16)
            : Color(red: 0.18, green: 0.34, blue: 0.37)
    }
}
