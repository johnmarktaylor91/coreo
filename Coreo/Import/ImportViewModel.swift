// ImportViewModel.swift
// Coreo
//
// ViewModel for the import screen. Manages the video import list,
// triggers audio sync, handles unreliable-result confirmation,
// and produces a CoreoProject on success.

import SwiftUI

/// ViewModel managing video imports and the sync-to-project flow.
@MainActor
final class ImportViewModel: ObservableObject {
    // MARK: - Published State

    /// Videos that have been successfully imported and probed.
    @Published var videos: [VideoAsset] = []

    /// True while the audio sync engine is running.
    @Published var isSyncing: Bool = false

    /// User-facing error message from the most recent failure, or nil.
    @Published var syncError: String?

    /// Videos whose sync confidence fell below the reliable threshold.
    @Published var unreliableVideos: [UnreliableVideo] = []

    /// Controls presentation of the unreliable-videos confirmation alert.
    @Published var showUnreliableAlert: Bool = false

    /// Number of video imports currently in progress.
    @Published var pendingImports: Int = 0

    /// Current sync progress fraction from 0...1.
    @Published var syncProgress: Double = 0

    /// User-facing phase label for the sync pipeline.
    @Published var syncPhaseLabel: String = ""

    /// Per-item import failures shown in the import UI.
    @Published var importErrors: [ImportErrorItem] = []

    // MARK: - Internal State

    /// Cached sync output held between the initial sync call and user
    /// confirmation of unreliable videos.
    private var pendingSyncOutput: AudioSyncOutput?

    /// Draft project identity used to copy imported media before sync.
    let projectID: UUID

    /// Store used for copied media and project persistence.
    let projectStore: ProjectStore

    /// Maximum supported videos for one Coreo project.
    nonisolated static let maxVideoCount: Int = 6

    /// Maximum file imports to process at once.
    private nonisolated static let maxConcurrentImports: Int = 3

    // MARK: - Init

    /// Creates an import view model.
    ///
    /// - Parameters:
    ///   - projectID: Draft project identity used for copied media.
    ///   - projectStore: Project store used for media copy operations.
    init(projectID: UUID = UUID(), projectStore: ProjectStore = ProjectStore()) {
        self.projectID = projectID
        self.projectStore = projectStore
        projectStore.removeLegacyProjectFile()
    }

    // MARK: - Types

    /// A video that failed the sync confidence check.
    struct UnreliableVideo: Identifiable {
        let id = UUID()
        let index: Int
        let filename: String
        let confidence: Float
        let reason: String
    }

    /// A visible import failure with optional retry URL.
    struct ImportErrorItem: Identifiable {
        let id = UUID()
        let filename: String
        let message: String
        let retryURL: URL?
    }

    // MARK: - Computed Properties

    /// True when the minimum requirements for sync are met.
    var canSync: Bool {
        videos.count >= 2 && videos.count <= Self.maxVideoCount && !isSyncing
    }

    /// Explanation for why sync is currently unavailable.
    var syncDisabledReason: String? {
        if videos.count < 2 {
            return "Add at least 2 videos to sync."
        }
        if videos.count > Self.maxVideoCount {
            return "Coreo supports up to 6 videos."
        }
        return nil
    }

    // MARK: - Video Management

    /// Imports a video from the given file URL.
    ///
    /// Extracts metadata and a thumbnail via `VideoAsset.from(url:)`.
    /// On failure, populates `syncError` with a descriptive message.
    ///
    /// - Parameter url: A file URL pointing to a video.
    func addVideo(from url: URL) async {
        guard Self.acceptedImportCount(existingCount: videos.count, requestedCount: 1) == 1 else {
            syncError = "Coreo supports up to 6 videos. Remove a video to add another."
            Haptic.error()
            return
        }

        syncError = nil
        let filename = url.lastPathComponent
        do {
            let asset = try await projectStore.importVideo(from: url, projectID: projectID)
            videos.append(asset)
        } catch {
            recordImportError(filename: filename, message: error.localizedDescription, retryURL: url)
        }
    }

    /// Imports multiple videos concurrently while preserving selected order.
    ///
    /// - Parameter urls: File URLs selected by the user.
    func addVideos(from urls: [URL]) async {
        guard !urls.isEmpty else { return }

        let acceptedCount = Self.acceptedImportCount(
            existingCount: videos.count,
            requestedCount: urls.count
        )
        guard acceptedCount > 0 else {
            syncError = "Coreo supports up to 6 videos. Remove a video to add another."
            Haptic.error()
            return
        }
        if acceptedCount < urls.count {
            syncError = "Only \(acceptedCount) more video(s) can be added. Coreo supports up to 6."
            Haptic.error()
        } else {
            syncError = nil
        }

        let selectedURLs = Array(urls.prefix(acceptedCount))
        pendingImports += selectedURLs.count
        defer { pendingImports = max(0, pendingImports - selectedURLs.count) }

        let results = await importAssets(from: selectedURLs)
        for result in results {
            switch result {
            case let .success(asset):
                videos.append(asset)
            case let .failure(failure):
                recordImportError(
                    filename: failure.url.lastPathComponent,
                    message: failure.error.localizedDescription,
                    retryURL: failure.url
                )
            }
        }
    }

    /// Retry one failed import item.
    ///
    /// - Parameter item: Failed import item to retry.
    func retryImport(_ item: ImportErrorItem) async {
        guard let retryURL = item.retryURL else { return }
        importErrors.removeAll { $0.id == item.id }
        await addVideo(from: retryURL)
    }

    /// Removes the video at the given index.
    ///
    /// - Parameter index: A valid index into `videos`.
    func removeVideo(at index: Int) {
        guard !isSyncing else { return }
        guard videos.indices.contains(index) else { return }
        let removed = videos[index]
        videos.remove(at: index)
        projectStore.deleteMedia(for: removed, projectID: projectID)
        syncError = nil
    }

    // MARK: - Sync

    /// Runs audio cross-correlation sync across all imported videos.
    ///
    /// If every video passes the confidence check, a `CoreoProject` is
    /// returned immediately. If any video is unreliable, the results are
    /// held in `pendingSyncOutput`, `unreliableVideos` is populated, and
    /// the alert is shown so the user can decide whether to include them.
    ///
    /// - Returns: A fully configured `CoreoProject`, or nil if the user
    ///   still needs to confirm unreliable videos (or if sync failed).
    func sync() async -> CoreoProject? {
        guard canSync else { return nil }

        isSyncing = true
        syncError = nil
        unreliableVideos = []
        pendingSyncOutput = nil
        syncProgress = 0
        syncPhaseLabel = "Analyzing audio..."

        do {
            let videoSnapshot = videos
            let inputs = videoSnapshot.map {
                (url: projectStore.mediaURL(for: $0, projectID: projectID), audioBitrate: $0.audioBitrate)
            }
            let output = try await AudioSyncEngine.sync(videos: inputs) { phase, fraction in
                Task { @MainActor in
                    switch phase {
                    case .extraction:
                        self.syncPhaseLabel = "Extracting audio..."
                        self.syncProgress = min(max(fraction * 0.55, 0), 0.55)
                    case .correlation:
                        self.syncPhaseLabel = "Matching audio..."
                        self.syncProgress = min(max(0.55 + fraction * 0.20, 0.55), 0.75)
                    }
                }
            }
            try Task.checkCancellation()

            // Check for unreliable results
            let unreliable = output.results.compactMap { result -> UnreliableVideo? in
                guard !result.isReliable else { return nil }
                let idx = result.videoIndex
                let name = idx < videoSnapshot.count
                    ? videoSnapshot[idx].originalFilename
                    : "Video \(idx)"
                let reason: String = switch result.status {
                case .synced:
                    "Low confidence"
                case .noAudio:
                    "No audio; align manually later"
                case let .failed(failureReason):
                    failureReason
                }
                return UnreliableVideo(
                    index: idx,
                    filename: name,
                    confidence: result.confidence,
                    reason: reason
                )
            }

            if unreliable.isEmpty {
                // All videos are reliable — build the project now
                syncPhaseLabel = "Finding dancers..."
                syncProgress = 0.75
                let project = await buildProject(from: output, videos: videoSnapshot)
                syncProgress = 1
                isSyncing = false
                Haptic.success()
                return project
            } else {
                // Park the output and ask the user
                pendingSyncOutput = output
                unreliableVideos = unreliable
                showUnreliableAlert = true
                isSyncing = false
                Haptic.error()
                return nil
            }
        } catch is CancellationError {
            syncError = "Sync cancelled."
            isSyncing = false
            syncProgress = 0
            syncPhaseLabel = ""
            return nil
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
            isSyncing = false
            syncProgress = 0
            syncPhaseLabel = ""
            Haptic.error()
            return nil
        }
    }

    /// Finalizes the project after the user responds to the unreliable-videos alert.
    ///
    /// - Parameter includeUnreliable: If true, unreliable videos are kept
    ///   in the project. If false, they are removed from the video list and
    ///   the offsets are recalculated for the remaining videos.
    /// - Returns: A `CoreoProject` if finalization succeeds, or nil.
    func finalizeProject(includeUnreliable: Bool) async -> CoreoProject? {
        guard let output = pendingSyncOutput else { return nil }

        if includeUnreliable {
            syncPhaseLabel = "Finding dancers..."
            syncProgress = 0.75
            let project = await buildProject(from: output, videos: videos)
            syncProgress = 1
            pendingSyncOutput = nil
            Haptic.success()
            return project
        } else {
            // Remove unreliable videos and rebuild
            let unreliableIndices = Set(unreliableVideos.map(\.index))
            var filteredVideos: [VideoAsset] = []

            for (index, video) in videos.enumerated() {
                if !unreliableIndices.contains(index), index < output.offsets.count {
                    filteredVideos.append(video)
                } else if unreliableIndices.contains(index) {
                    projectStore.deleteMedia(for: video, projectID: projectID)
                }
            }

            // Need at least 2 videos after filtering
            guard filteredVideos.count >= 2 else {
                syncError = "Not enough reliable videos remain. Need at least 2."
                pendingSyncOutput = nil
                return nil
            }

            videos = filteredVideos

            var project = makeProject(
                from: output,
                videos: filteredVideos,
                referenceIndex: 0,
                audioSourceIndex: selectBestAudioSource(from: filteredVideos)
            )
            syncPhaseLabel = "Finding dancers..."
            syncProgress = 0.75
            await applyCropOverrides(to: &project)
            syncProgress = 1
            pendingSyncOutput = nil
            Haptic.success()
            return project
        }
    }

    /// Reset sync UI state after a user cancellation request.
    func cancelSync() {
        syncError = "Sync cancelled."
        isSyncing = false
        syncProgress = 0
        syncPhaseLabel = ""
    }

    /// Return how many requested videos can be accepted under the max cap.
    ///
    /// - Parameters:
    ///   - existingCount: Number of videos already imported.
    ///   - requestedCount: Number of new videos requested.
    /// - Returns: Number of videos that may be imported.
    nonisolated static func acceptedImportCount(existingCount: Int, requestedCount: Int) -> Int {
        let remaining = max(0, maxVideoCount - existingCount)
        return min(max(0, requestedCount), remaining)
    }

    // MARK: - Private Helpers

    /// Constructs a CoreoProject from sync output, applying offsets,
    /// selecting the best audio source, and computing smart crop rects.
    private func buildProject(from output: AudioSyncOutput, videos videoList: [VideoAsset]) async -> CoreoProject {
        var project = makeProject(
            from: output,
            videos: videoList,
            referenceIndex: output.referenceIndex,
            audioSourceIndex: output.audioSourceIndex
        )
        await applyCropOverrides(to: &project)
        return project
    }

    /// Constructs a project from videos and sync output.
    private func makeProject(
        from output: AudioSyncOutput,
        videos videoList: [VideoAsset],
        referenceIndex: Int,
        audioSourceIndex: Int
    ) -> CoreoProject {
        var updatedVideos = videoList
        for index in updatedVideos.indices {
            updatedVideos[index].syncOffsetSeconds = index < output.offsets.count ? output.offsets[index] : 0
            if let result = output.results.first(where: { $0.videoIndex == index }) {
                updatedVideos[index].syncStatus = result.status
            }
        }

        let safeReferenceIndex = updatedVideos.indices.contains(referenceIndex) ? referenceIndex : 0
        let safeAudioIndex = updatedVideos.indices.contains(audioSourceIndex) ? audioSourceIndex : safeReferenceIndex
        return CoreoProject(
            id: projectID,
            name: "New Project",
            videos: updatedVideos,
            referenceVideoID: updatedVideos[safeReferenceIndex].id,
            audioSourceVideoID: updatedVideos[safeAudioIndex].id
        )
    }

    /// Imports selected URLs with bounded concurrency.
    private func importAssets(from urls: [URL]) async -> [Result<VideoAsset, ImportFailure>] {
        await withTaskGroup(of: (Int, Result<VideoAsset, ImportFailure>).self) { group in
            var nextIndex = 0
            var activeCount = 0
            var results = [Result<VideoAsset, ImportFailure>?](repeating: nil, count: urls.count)

            func addNextIfPossible() {
                while activeCount < Self.maxConcurrentImports, nextIndex < urls.count {
                    let index = nextIndex
                    let url = urls[index]
                    nextIndex += 1
                    activeCount += 1

                    group.addTask {
                        do {
                            let asset = try await self.projectStore.importVideo(
                                from: url,
                                projectID: self.projectID
                            )
                            return (index, .success(asset))
                        } catch {
                            return (index, .failure(ImportFailure(url: url, error: error)))
                        }
                    }
                }
            }

            addNextIfPossible()
            while activeCount > 0, let result = await group.next() {
                activeCount -= 1
                results[result.0] = result.1
                addNextIfPossible()
            }

            return results.compactMap { $0 }
        }
    }

    /// Record a per-item import error.
    private func recordImportError(filename: String, message: String, retryURL: URL?) {
        importErrors.append(
            ImportErrorItem(
                filename: filename,
                message: "Failed to import \(filename): \(message)",
                retryURL: retryURL
            )
        )
        syncError = "Some videos couldn't be imported."
        Haptic.error()
    }

    /// Failed file import result.
    private struct ImportFailure: Error {
        let url: URL
        let error: Error
    }

    /// Runs person detection on each video and stores auto-crop rects.
    private func applyCropOverrides(to project: inout CoreoProject) async {
        let inputs = project.videos.map {
            (url: projectStore.mediaURL(for: $0, projectID: projectID), dimensions: $0.dimensions)
        }
        let cropRects = await SmartCropEngine.computeCropRects(for: inputs)

        for (index, rect) in cropRects.enumerated() {
            if project.videos.indices.contains(index) {
                project.videos[index].autoCropRect = rect
            }
        }
    }

    /// Picks the video with the highest audio bitrate as the audio source.
    private func selectBestAudioSource(from videoList: [VideoAsset]) -> Int {
        guard !videoList.isEmpty else { return 0 }
        var bestIndex = 0
        var bestBitrate = 0
        for (index, video) in videoList.enumerated() {
            if video.audioBitrate > bestBitrate {
                bestBitrate = video.audioBitrate
                bestIndex = index
            }
        }
        return bestIndex
    }
}
