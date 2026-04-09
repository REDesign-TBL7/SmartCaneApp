/*
 File: SpeechManager.swift
 Purpose:
 This file wraps AVSpeechSynthesizer so the app can speak important updates aloud.

 Accessibility note:
 Blind users need both app speech and VoiceOver-friendly UI labels. This manager
 handles app speech plus VoiceOver announcements for important state changes.
*/

import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SpeechManager: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var lastSpokenMessage = ""
    private var lastAnnouncementDate = Date.distantPast
    private let minimumRepeatInterval: TimeInterval = 1.2

    /// Speaks a short sentence aloud.
    func speak(_ message: String, interrupt: Bool = false, force: Bool = false) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return
        }

        if !force,
           trimmedMessage == lastSpokenMessage,
           Date().timeIntervalSince(lastAnnouncementDate) < minimumRepeatInterval {
            return
        }

        if interrupt, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        configurePlaybackSession()

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = 0.48
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
        postVoiceOverAnnouncement(trimmedMessage)
        lastSpokenMessage = trimmedMessage
        lastAnnouncementDate = Date()
    }

    /// Speaks urgent events like disconnects and interrupts older speech.
    func speakUrgent(_ message: String) {
        speak(message, interrupt: true)
    }

    /// Repeats the last spoken message on demand.
    func repeatLastMessage() {
        guard !lastSpokenMessage.isEmpty else {
            speak("No spoken update yet.", interrupt: true, force: true)
            return
        }

        speak(lastSpokenMessage, interrupt: true, force: true)
    }

    private func postVoiceOverAnnouncement(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }

    private func configurePlaybackSession() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true, options: [])
        } catch {
            // If audio session setup fails, still attempt speech. The synthesizer
            // may work under the system default session, and failing silently here
            // would make the Read button unusable.
        }
    }
}
