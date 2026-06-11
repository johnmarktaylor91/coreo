// ImportView.swift
// Coreo
//
// Screen 1: the video import drop zone. Users add videos from the
// photo library or Files app, preview thumbnails, and trigger audio
// sync. On successful sync the callback delivers a CoreoProject to
// the parent navigation.

import PhotosUI
import SwiftUI

/// The import screen where users add videos and kick off audio sync.
struct ImportView: View {
    @StateObject private var viewModel = ImportViewModel()

    /// Called when sync completes successfully with a ready-to-use project.
    var onSyncComplete: (CoreoProject) -> Void

    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    /// App background color.
    private let backgroundColor = Color(red: 0.04, green: 0.04, blue: 0.04)

    /// Coral accent used for primary actions.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                if viewModel.videos.isEmpty {
                    emptyState
                } else {
                    populatedState
                }
            }
        }
        .navigationTitle("Coreo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                addMenuButton
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 6,
            matching: .videos
        )
        .onChange(of: selectedPhotos) { newItems in
            handlePhotoPickerSelection(newItems)
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                Task { @MainActor in
                    viewModel.pendingImports += urls.count
                    for url in urls {
                        await viewModel.addVideo(from: url)
                        viewModel.pendingImports -= 1
                    }
                }
            }
        }
        .onChange(of: viewModel.pendingImports) { count in
            if count == 0 && viewModel.canSync {
                Task {
                    if let project = await viewModel.sync() {
                        onSyncComplete(project)
                    }
                }
            }
        }
        .alert("Unreliable Sync", isPresented: $viewModel.showUnreliableAlert) {
            Button("Include Anyway") {
                Task {
                    if let project = await viewModel.finalizeProject(includeUnreliable: true) {
                        onSyncComplete(project)
                    }
                }
            }
            Button("Remove", role: .destructive) {
                Task {
                    if let project = await viewModel.finalizeProject(includeUnreliable: false) {
                        onSyncComplete(project)
                    }
                }
            }
        } message: {
            Text(unreliableAlertMessage)
        }
    }

    // MARK: - Empty State

    /// Shown when no videos have been imported yet.
    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundColor(accentCoral)

                Text("Add Videos")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                Text("Import 2\u{2013}6 videos of the same dance\nfrom different angles")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                importFromLibraryButton
                importFromFilesButton
            }
            .padding(.top, 8)

            Spacer()

            if let errorMessage = viewModel.syncError {
                errorBanner(errorMessage)
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Populated State

    /// Shown once at least one video has been imported.
    private var populatedState: some View {
        VStack(spacing: 0) {
            // Thumbnail row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(viewModel.videos.enumerated()), id: \.element.id) { index, video in
                        VideoThumbnailView(video: video) {
                            viewModel.removeVideo(at: index)
                        }
                    }

                    // Inline add button
                    addTileButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(height: 140)

            Spacer()

            // Error display
            if let errorMessage = viewModel.syncError {
                errorBanner(errorMessage)
                    .padding(.bottom, 12)
            }

            // Sync progress (auto-triggered) or retry button on error
            if viewModel.isSyncing {
                syncProgressView
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            } else if viewModel.syncError != nil && viewModel.canSync {
                syncButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    // MARK: - Buttons

    /// Menu for adding videos, shown in the toolbar.
    private var addMenuButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .foregroundColor(accentCoral)
        }
    }

    /// Large button for importing from the photo library (empty state).
    private var importFromLibraryButton: some View {
        Button {
            showPhotoPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                Text("Photo Library")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(accentCoral)
            .foregroundColor(.white)
            .cornerRadius(CornerRadius.large)
        }
        .buttonStyle(.coreoProminent)
    }

    /// Secondary button for importing from Files (empty state).
    private var importFromFilesButton: some View {
        Button {
            showFilePicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                Text("Files")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(CornerRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.coreoProminent)
    }

    /// Small tile at the end of the thumbnail row for adding more videos.
    private var addTileButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            VStack {
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundColor(accentCoral)
            }
            .frame(width: 80, height: 100)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
        }
    }

    /// The "Sync & Go" button shown when 2+ videos are ready.
    private var syncButton: some View {
        Button {
            Haptic.medium()
            Task {
                if let project = await viewModel.sync() {
                    onSyncComplete(project)
                }
            }
        } label: {
            Text("Sync & Go")
                .font(.headline)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    LinearGradient(
                        colors: [
                            accentCoral,
                            Color(red: 0.91, green: 0.24, blue: 0.24),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(CornerRadius.xl)
        }
        .buttonStyle(.coreoProminent)
        .animation(CoreoAnimation.slow, value: viewModel.canSync)
    }

    /// Progress indicator shown during sync.
    private var syncProgressView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(accentCoral)
            Text("Syncing audio\u{2026}")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }

    // MARK: - Error Banner

    /// Displays an error message in red.
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(Color(red: 1.0, green: 0.3, blue: 0.3))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    // MARK: - Unreliable Alert

    /// Builds a human-readable message listing all unreliable videos.
    private var unreliableAlertMessage: String {
        let names = viewModel.unreliableVideos
            .map { $0.filename }
            .joined(separator: ", ")
        return "Couldn't confidently match: \(names). Audio may not overlap. Include anyway?"
    }

    // MARK: - Photo Picker Handling

    /// Processes items chosen from the PhotosPicker.
    private func handlePhotoPickerSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        for item in items {
            viewModel.pendingImports += 1
            Task {
                defer { viewModel.pendingImports -= 1 }
                guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
                    return
                }
                await viewModel.addVideo(from: movie.url)
            }
        }

        selectedPhotos = []
    }
}

// MARK: - VideoTransferable

/// A Transferable wrapper that copies a picked video to a temporary
/// file and exposes its URL.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { receivedFile in
            let tempDir = FileManager.default.temporaryDirectory
            let filename = receivedFile.file.lastPathComponent
            let destination = tempDir.appendingPathComponent(
                UUID().uuidString + "-" + filename
            )
            try FileManager.default.copyItem(at: receivedFile.file, to: destination)
            return VideoTransferable(url: destination)
        }
    }
}
