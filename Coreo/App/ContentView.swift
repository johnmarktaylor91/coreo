// ContentView.swift
// Coreo
//
// Root navigation container. Manages the two-screen flow:
// ImportView (Screen 1) -> WorkspaceView (Screen 2) after successful sync.
// Navigation is driven by a single @State (currentProject) to avoid
// race conditions between separate navigation path and data states.

import SwiftUI

/// Root view that manages navigation between Import and Workspace screens.
struct ContentView: View {
    @State private var currentProject: CoreoProject?

    var body: some View {
        NavigationStack {
            ImportView(onSyncComplete: { project in
                currentProject = project
            })
            .navigationDestination(isPresented: Binding(
                get: { currentProject != nil },
                set: { if !$0 { currentProject = nil } }
            )) {
                if let project = currentProject {
                    WorkspaceView(project: project)
                }
            }
        }
        .tint(Color(red: 1.0, green: 0.42, blue: 0.21))
    }
}
