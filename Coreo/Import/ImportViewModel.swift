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

    // MARK: - Internal State

    /// Cached sync output held between the initial sync call and user
    /// confirmation of unreliable videos.
    private var pendingSyncOutput: AudioSyncOutput?

    // MARK: - Types

    /// A video that failed the sync confidence check.
    struct UnreliableVideo: Identifiable {
        let id = UUID()
        let index: Int
        let filename: String
        let confidence: Float
    }

    // MARK: - Computed Properties

    /// True when the minimum requirements for sync are met.
    var canSync: Bool {
        videos.count >= 2 && !isSyncing
    }

    // MARK: - Video Management

    /// Imports a video from the given file URL.
    ///
    /// Extracts metadata and a thumbnail via `VideoAsset.from(url:)`.
    /// On failure, populates `syncError` with a descriptive message.
    ///
    /// - Parameter url: A file URL pointing to a video.
    func addVideo(from url: URL) async {
        syncError = nil
        let filename = url.lastPathComponent
        do {
            let asset = try await VideoAsset.from(url: url)
            videos.append(asset)
        } catch {
            syncError = "Failed to import \(filename): \(error.localizedDescription)"
        }
    }

    /// Removes the video at the given index.
    ///
    /// - Parameter index: A valid index into `videos`.
    func removeVideo(at index: Int) {
        guard videos.indices.contains(index) else { return }
        videos.remove(at: index)
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

        do {
            let inputs = videos.map { (url: $0.localURL, audioBitrate: $0.audioBitrate) }
            let output = try await AudioSyncEngine.sync(videos: inputs)

            // Check for unreliable results
            let unreliable = output.results.compactMap { result -> UnreliableVideo? in
                guard !result.isReliable else { return nil }
                let idx = result.videoIndex
                let name = idx < videos.count
                    ? videos[idx].localURL.lastPathComponent
                    : "Video \(idx)"
                return UnreliableVideo(
                    index: idx,
                    filename: name,
                    confidence: result.confidence
                )
            }

            if unreliable.isEmpty {
                // All videos are reliable — build the project now
                let project = await buildProject(from: output)
                isSyncing = false
                return project
            } else {
                // Park the output and ask the user
                pendingSyncOutput = output
                unreliableVideos = unreliable
                showUnreliableAlert = true
                isSyncing = false
                return nil
            }
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
            isSyncing = false
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
            let project = await buildProject(from: output)
            pendingSyncOutput = nil
            return project
        } else {
            // Remove unreliable videos and rebuild
            let unreliableIndices = Set(unreliableVideos.map(\.index))
            var filteredVideos: [VideoAsset] = []
            var filteredOffsets: [TimeInterval] = []

            for (index, video) in videos.enumerated() {
                if !unreliableIndices.contains(index), index < output.offsets.count {
                    filteredVideos.append(video)
                    filteredOffsets.append(output.offsets[index])
                }
            }

            // Need at least 2 videos after filtering
            guard filteredVideos.count >= 2 else {
                syncError = "Not enough reliable videos remain. Need at least 2."
                pendingSyncOutput = nil
                return nil
            }

            videos = filteredVideos

            var project = CoreoProject(
                name: "New Project",
                videos: filteredVideos,
                referenceVideoIndex: 0,
                syncOffsets: filteredOffsets
            )
            project.audioSourceIndex = selectBestAudioSource(from: filteredVideos)
            project.cropOverrides = await computeCropOverrides(for: filteredVideos)
            pendingSyncOutput = nil
            return project
        }
    }

    // MARK: - Private Helpers

    /// Constructs a CoreoProject from sync output, applying offsets,
    /// selecting the best audio source, and computing smart crop rects.
    private func buildProject(from output: AudioSyncOutput) async -> CoreoProject {
        var project = CoreoProject(
            name: "New Project",
            videos: videos,
            referenceVideoIndex: output.referenceIndex,
            syncOffsets: output.offsets
        )
        project.audioSourceIndex = output.audioSourceIndex
        project.cropOverrides = await computeCropOverrides(for: videos)
        return project
    }

    /// Runs person detection on each video and produces a crop-overrides
    /// dictionary keyed by video index.
    private func computeCropOverrides(for videoList: [VideoAsset]) async -> [Int: CGRect] {
        let inputs = videoList.map { (url: $0.localURL, dimensions: $0.dimensions) }
        let cropRects = await SmartCropEngine.computeCropRects(for: inputs)

        var overrides: [Int: CGRect] = [:]
        for (index, rect) in cropRects.enumerated() {
            if let rect {
                overrides[index] = rect
            }
        }
        return overrides.isEmpty ? [:] : overrides
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
