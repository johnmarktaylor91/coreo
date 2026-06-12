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

    /// Most recently saved project offered for restore.
    var lastProject: LoadedProject?

    /// Called when the user chooses to continue a saved project.
    var onContinueProject: (CoreoProject) -> Void

    /// Called when the user discards the saved project and starts fresh.
    var onStartNew: () -> Void

    /// Called when sync completes successfully with a ready-to-use project.
    var onSyncComplete: (CoreoProject) -> Void

    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var syncTask: Task<Void, Never>?

    /// App background color.
    private let backgroundColor = Color(red: 0.04, green: 0.04, blue: 0.04)

    /// Coral accent used for primary actions.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                if let lastProject {
                    continueProjectPanel(lastProject.project)
                }
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
                Task {
                    let acceptedCount = ImportViewModel.acceptedImportCount(
                        existingCount: viewModel.videos.count,
                        requestedCount: urls.count
                    )
                    if acceptedCount != urls.count {
                        viewModel.syncError = acceptedCount == 0
                            ? "Coreo supports up to 6 videos. Remove a video to add another."
                            : "Only \(acceptedCount) more video(s) can be added. Coreo supports up to 6."
                        Haptic.error()
                        if acceptedCount == 0 {
                            return
                        }
                    }
                    await viewModel.addVideos(from: Array(urls.prefix(acceptedCount)))
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

    /// Simple restore choice for the last saved project.
    private func continueProjectPanel(_ project: CoreoProject) -> some View {
        VStack(spacing: 10) {
            Text("Continue \(project.name)?")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)

            HStack(spacing: 12) {
                Button("Continue") {
                    onContinueProject(project)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(accentCoral)
                .cornerRadius(8)

                Button("Start New") {
                    onStartNew()
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1))
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

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

            importErrorList
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
                    if viewModel.videos.count < ImportViewModel.maxVideoCount {
                        addTileButton
                    }

                    ForEach(0..<viewModel.pendingImports, id: \.self) { _ in
                        importPlaceholderTile
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(height: 140)

            Spacer()

            if viewModel.pendingImports > 0 {
                Text("Importing \(viewModel.pendingImports) video(s)...")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .padding(.bottom, 12)
            }

            importErrorList
                .padding(.bottom, 12)

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
            } else if viewModel.canSync {
                syncButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let reason = viewModel.syncDisabledReason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
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
            .disabled(viewModel.videos.count >= ImportViewModel.maxVideoCount || viewModel.isSyncing)

            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            .disabled(viewModel.videos.count >= ImportViewModel.maxVideoCount || viewModel.isSyncing)
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
        .disabled(viewModel.isSyncing)
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
        .disabled(viewModel.isSyncing)
    }

    /// Small tile at the end of the thumbnail row for adding more videos.
    private var addTileButton: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            .disabled(viewModel.videos.count >= ImportViewModel.maxVideoCount || viewModel.isSyncing)

            Button {
                showFilePicker = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            .disabled(viewModel.videos.count >= ImportViewModel.maxVideoCount || viewModel.isSyncing)
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
            syncTask = Task {
                if let project = await viewModel.sync() {
                    onSyncComplete(project)
                }
                syncTask = nil
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
            ProgressView(value: viewModel.syncProgress)
                .tint(accentCoral)
            HStack {
                Text(viewModel.syncPhaseLabel.isEmpty ? "Preparing..." : viewModel.syncPhaseLabel)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                Spacer()
                Button("Cancel") {
                    syncTask?.cancel()
                    syncTask = nil
                    viewModel.cancelSync()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(accentCoral)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }

    /// Placeholder shown for imports still being processed.
    private var importPlaceholderTile: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.06))
            .overlay {
                ProgressView()
                    .tint(accentCoral)
            }
            .frame(width: 80, height: 100)
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

    /// Displays per-file import errors with retry where possible.
    private var importErrorList: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.importErrors) { item in
                HStack(spacing: 8) {
                    Text(item.message)
                        .font(.caption)
                        .foregroundColor(Color(red: 1.0, green: 0.3, blue: 0.3))
                        .lineLimit(2)
                    Spacer()
                    if item.retryURL != nil {
                        Button("Retry") {
                            Task {
                                await viewModel.retryImport(item)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(accentCoral)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Unreliable Alert

    /// Builds a human-readable message listing all unreliable videos.
    private var unreliableAlertMessage: String {
        let names = viewModel.unreliableVideos
            .map { "\($0.filename) (\($0.reason))" }
            .joined(separator: ", ")
        return "Couldn't automatically sync: \(names). Videos without audio can be aligned manually later. Include anyway?"
    }

    // MARK: - Photo Picker Handling

    /// Processes items chosen from the PhotosPicker.
    private func handlePhotoPickerSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        Task {
            let acceptedCount = ImportViewModel.acceptedImportCount(
                existingCount: viewModel.videos.count,
                requestedCount: items.count
            )
            guard acceptedCount > 0 else {
                viewModel.syncError = "Coreo supports up to 6 videos. Remove a video to add another."
                Haptic.error()
                return
            }
            if acceptedCount < items.count {
                viewModel.syncError = "Only \(acceptedCount) more video(s) can be added. Coreo supports up to 6."
                Haptic.error()
            }

            let selectedItems = Array(items.prefix(acceptedCount))
            viewModel.pendingImports += selectedItems.count
            defer { viewModel.pendingImports = max(0, viewModel.pendingImports - selectedItems.count) }

            await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
                var nextIndex = 0
                var activeCount = 0

                func addNextIfPossible() {
                    while activeCount < 3, nextIndex < selectedItems.count {
                        let index = nextIndex
                        let item = selectedItems[index]
                        nextIndex += 1
                        activeCount += 1

                        group.addTask {
                            do {
                                guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                                    throw CocoaError(.fileReadUnknown)
                                }
                                return (index, .success(movie.url))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }
                }

                var orderedURLs = Array<URL?>(repeating: nil, count: selectedItems.count)
                var failures: [(Int, Error)] = []
                addNextIfPossible()
                while activeCount > 0, let result = await group.next() {
                    activeCount -= 1
                    switch result.1 {
                    case .success(let url):
                        orderedURLs[result.0] = url
                    case .failure(let error):
                        failures.append((result.0, error))
                    }
                    addNextIfPossible()
                }

                for failure in failures {
                    let filename = "Photo \(failure.0 + 1)"
                    viewModel.importErrors.append(
                        ImportViewModel.ImportErrorItem(
                            filename: filename,
                            message: "Failed to import \(filename): \(failure.1.localizedDescription)",
                            retryURL: nil
                        )
                    )
                    viewModel.syncError = "Some videos couldn't be imported."
                    Haptic.error()
                }

                await viewModel.addVideos(from: orderedURLs.compactMap { $0 })
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
