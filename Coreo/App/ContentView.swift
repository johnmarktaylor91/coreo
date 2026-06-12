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
    @State private var lastProject: LoadedProject?
    private let projectStore = ProjectStore()

    var body: some View {
        NavigationStack {
            ImportView(lastProject: lastProject, onContinueProject: { project in
                currentProject = project
                lastProject = nil
            }, onStartNew: {
                if let id = lastProject?.project.id {
                    projectStore.deleteProject(projectID: id)
                }
                lastProject = nil
            }, onSyncComplete: { project in
                currentProject = project
                lastProject = nil
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
        .onAppear {
            guard lastProject == nil, currentProject == nil else { return }
            lastProject = projectStore.loadMostRecentProject()
        }
    }
}
