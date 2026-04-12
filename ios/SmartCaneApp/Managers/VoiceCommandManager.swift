/*
 File: VoiceCommandManager.swift
 Purpose:
 This file adds optional push-to-speak voice control for the smart cane app.

 Design notes:
 The app does not listen all the time. The user taps the microphone button once,
 says a short command, and the app submits it automatically after a short pause.
 This keeps the app usable with normal typing and Apple's VoiceOver while
 avoiding accidental background speech.
*/

import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceCommandManager: ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""
    @Published var statusText = "Voice command ready"

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-SG"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var autoSubmitWorkItem: DispatchWorkItem?
    private let autoSubmitDelay: TimeInterval = 1.25

    func toggleListening(
        connectionManager: CaneConnectionManager,
        locationManager: LocationManager,
        speechManager: SpeechManager
    ) {
        if isListening {
            stopListeningAndProcess(
                connectionManager: connectionManager,
                locationManager: locationManager,
                speechManager: speechManager
            )
        } else {
            startListening(
                connectionManager: connectionManager,
                locationManager: locationManager,
                speechManager: speechManager
            )
        }
    }

    private func startListening(
        connectionManager: CaneConnectionManager,
        locationManager: LocationManager,
        speechManager: SpeechManager
    ) {
        Task {
            let hasPermission = await requestSpeechAndMicrophoneAccess()
            guard hasPermission else {
                statusText = "Speech permission needed"
                speechManager.speak("Please allow microphone and speech recognition access.", interrupt: true)
                return
            }

            guard let speechRecognizer, speechRecognizer.isAvailable else {
                statusText = "Speech recognizer unavailable"
                speechManager.speak("Voice commands are not available right now.", interrupt: true)
                return
            }

            do {
                try beginRecognition(
                    with: speechRecognizer,
                    connectionManager: connectionManager,
                    locationManager: locationManager,
                    speechManager: speechManager
                )
            } catch {
                statusText = "Could not start voice command"
                speechManager.speak("Could not start voice command.", interrupt: true)
            }
        }
    }

    private func beginRecognition(
        with speechRecognizer: SFSpeechRecognizer,
        connectionManager: CaneConnectionManager,
        locationManager: LocationManager,
        speechManager: SpeechManager
    ) throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        autoSubmitWorkItem?.cancel()
        autoSubmitWorkItem = nil
        transcript = ""

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        statusText = "Listening"

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            Task { @MainActor in
                if let result {
                    let newTranscript = result.bestTranscription.formattedString
                    if newTranscript != self.transcript {
                        self.transcript = newTranscript
                        self.scheduleAutoSubmit(
                            connectionManager: connectionManager,
                            locationManager: locationManager,
                            speechManager: speechManager
                        )
                    }

                    if result.isFinal {
                        self.stopListeningAndProcess(
                            connectionManager: connectionManager,
                            locationManager: locationManager,
                            speechManager: speechManager
                        )
                    }
                }

                if error != nil {
                    self.stopAudioCapture()
                    self.statusText = "Voice command stopped"
                }
            }
        }
    }

    private func scheduleAutoSubmit(
        connectionManager: CaneConnectionManager,
        locationManager: LocationManager,
        speechManager: SpeechManager
    ) {
        autoSubmitWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak connectionManager, weak locationManager, weak speechManager] in
            Task { @MainActor in
                guard let self,
                      let connectionManager,
                      let locationManager,
                      let speechManager,
                      self.isListening,
                      !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                self.stopListeningAndProcess(
                    connectionManager: connectionManager,
                    locationManager: locationManager,
                    speechManager: speechManager
                )
            }
        }

        autoSubmitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoSubmitDelay, execute: workItem)
    }

    private func stopListeningAndProcess(
        connectionManager: CaneConnectionManager,
        locationManager: LocationManager,
        speechManager: SpeechManager
    ) {
        guard isListening else {
            return
        }

        let spokenText = transcript
        stopAudioCapture()

        Task {
            await handleCommand(
                spokenText,
                connectionManager: connectionManager,
                locationManager: locationManager,
                speechManager: speechManager
            )
        }
    }

    private func stopAudioCapture() {
        autoSubmitWorkItem?.cancel()
        autoSubmitWorkItem = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleCommand(
        _ spokenText: String,
        connectionManager: CaneConnectionManager,
        locationManager: LocationManager,
        speechManager: SpeechManager
    ) async {
        let commandText = spokenText.normalizedVoiceCommandText
        guard !commandText.isEmpty else {
            statusText = "No command heard"
            speechManager.speak("I did not hear a command.", interrupt: true)
            return
        }

        statusText = "Heard: \(spokenText)"

        if commandText == "cancel" || commandText == "never mind" {
            speechManager.speak("Cancelled.", interrupt: true)
            return
        }

        if commandText.contains("help") || commandText == "what can i say" {
            speechManager.speak("Try: connect cane, disconnect cane, status, search for a place, go home, or stop navigation.", interrupt: true)
            return
        }

        if commandText.contains("disconnect") {
            connectionManager.disconnectFromCane()
            speechManager.speak("Cane disconnected.", interrupt: true)
            return
        }

        if commandText.contains("connect") {
            connectionManager.connectToCane()
            speechManager.speak(
                "Connecting to the cane over Personal Hotspot.",
                interrupt: true
            )
            return
        }

        if commandText.contains("status") || commandText == "what is my status" {
            speechManager.speak(statusSummary(connectionManager: connectionManager, locationManager: locationManager), interrupt: true)
            return
        }

        if commandText.contains("stop navigation") || commandText == "stop" {
            locationManager.clearNavigation()
            connectionManager.sendNavigationCommand(.stop, instructionText: "Navigation stopped by user")
            speechManager.speak("Navigation stopped.", interrupt: true)
            return
        }

        if commandText == "go home" || commandText == "home" {
            if locationManager.selectFavorite(named: "home") {
                speechManager.speak("Starting navigation to Home.", interrupt: true)
            } else {
                speechManager.speak("Home is not saved yet.", interrupt: true)
            }
            return
        }

        if let destinationQuery = destinationQuery(from: commandText) {
            if locationManager.selectFavorite(named: destinationQuery) {
                speechManager.speak("Starting navigation to \(destinationQuery).", interrupt: true)
                return
            }

            let response = await locationManager.startNavigationFromVoiceQuery(destinationQuery)
            speechManager.speak(response, interrupt: true)
            return
        }

        if locationManager.selectFavorite(named: commandText) {
            speechManager.speak("Starting navigation to \(spokenText).", interrupt: true)
            return
        }

        speechManager.speak("I did not understand. Say help for commands.", interrupt: true)
    }

    private func destinationQuery(from commandText: String) -> String? {
        let prefixes = [
            "search for ",
            "search ",
            "navigate to ",
            "go to ",
            "find "
        ]

        for prefix in prefixes where commandText.hasPrefix(prefix) {
            let query = String(commandText.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : query
        }

        return nil
    }

    private func statusSummary(connectionManager: CaneConnectionManager, locationManager: LocationManager) -> String {
        let pairing = connectionManager.pairedDevice.map {
            "Cane network \($0.deviceName)."
        } ?? "Turn on Personal Hotspot and wait for BLE diagnostics to discover the Pi first."
        let connection = "Cane \(connectionManager.caneState.connectionStatus.rawValue.lowercased())."
        let navigation = locationManager.hasActiveNavigation
            ? "Navigating to \(locationManager.navigationStatusValue)."
            : "No active navigation."
        let connectionCommand = connectionManager.caneState.connectionStatus == .connected
            ? "Say disconnect cane to disconnect."
            : "Say connect cane after turning on Personal Hotspot."
        let navigationCommand = locationManager.hasActiveNavigation
            ? "Say stop, or search for a new destination."
            : "Search for a destination."
        return "\(pairing) \(connection) \(navigation) \(connectionCommand) \(navigationCommand)"
    }

    private func requestSpeechAndMicrophoneAccess() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechAuthorized else {
            return false
        }

        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { isAllowed in
                continuation.resume(returning: isAllowed)
            }
        }
    }
}

extension String {
    var normalizedVoiceCommandText: String {
        lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
    }
}
