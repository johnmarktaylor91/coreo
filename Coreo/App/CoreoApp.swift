// CoreoApp.swift
// Coreo
//
// App entry point. Forces dark mode and configures the audio session
// for video playback (plays through speaker even in silent mode).

import AVFoundation
import SwiftUI

@main
struct CoreoApp: App {
    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }

    /// Sets up the audio session for video playback.
    /// Category `.playback` ensures audio plays through the speaker
    /// even when the device silent switch is on.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}
