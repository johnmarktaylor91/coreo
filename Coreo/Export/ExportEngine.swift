// ExportEngine.swift
// Coreo
//
// The main export pipeline. Produces a single .mp4 from a CoreoProject by:
// 1. Building an AVMutableComposition with all video tracks (sync-offset aligned)
//    and the selected audio track
// 2. Optionally applying speed/hold modifications
// 3. Optionally appending a 1-second end bumper
// 4. Building an AVMutableVideoComposition with layout transforms AFTER all
//    composition modifications (so the instruction covers the final duration)
// 5. Leaving an annotation-rendering hook for the custom compositor
// 6. Exporting via AVAssetExportSession

import AVFoundation
import UIKit

/// Errors that can occur during the export pipeline.
enum ExportError: Error, LocalizedError {
    case noVideos
    case compositionFailed(String)
    case exportFailed(String)
    case diskFull
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideos:
            "No videos to export."
        case let .compositionFailed(detail):
            "Composition failed: \(detail)"
        case let .exportFailed(detail):
            "Export failed: \(detail)"
        case .diskFull:
            "Not enough disk space to complete the export."
        case .cancelled:
            "Export was cancelled."
        }
    }
}

/// Handles exporting the multi-angle video composition as a single .mp4 file.
enum ExportEngine {
    private static let timescale: CMTimeScale = 600

    private struct LoadedSource {
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let displaySize: CGSize
        let preferredTransform: CGAffineTransform
        let videoTimeRange: CMTimeRange
        let audioTimeRange: CMTimeRange?
        let nominalFrameRate: Float
    }

    // MARK: - Public

    /// Exports the project as a single composited video file.
    static func export(
        project: CoreoProject,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard !project.videos.isEmpty else {
            throw ExportError.noVideos
        }

        try Task.checkCancellation()

        var project = project
        project.sanitizeReferences()

        progressHandler(0.0)

        // Step 1: Load assets.
        let sources = try await loadSources(project: project)
        try Task.checkCancellation()
        progressHandler(0.05)

        let plan = try ExportPlan(
            project: project,
            sources: makePlanSources(project: project, sources: sources),
            renderSize: resolution
        )
        guard plan.panels.count == project.videos.count else {
            throw ExportError.compositionFailed(
                "Layout returned \(plan.panels.count) panels for \(project.videos.count) videos."
            )
        }

        try checkDiskSpace(requiredBytes: plan.estimatedOutputBytes)
        try Task.checkCancellation()

        // Step 2: Build composition with video + audio tracks.
        let (composition, videoTracks, videoSizes, trackTransforms, sourceVideoTracks) = try await buildComposition(
            project: project,
            sources: sources,
            plan: plan
        )
        try Task.checkCancellation()
        progressHandler(0.15)

        // Step 3: Apply speed/hold (if any). Done before video composition
        // so the instruction timeRange reflects the final duration.
        if !project.speedSegments.isEmpty {
            try applySpeedSegments(
                to: composition,
                plan: plan,
                sourceVideoTracks: sourceVideoTracks,
                compositionVideoTracks: videoTracks
            )
        }
        try Task.checkCancellation()
        progressHandler(0.20)

        // Record the main content duration before bumper.
        let mainContentDuration = composition.duration

        // Step 4: Append end bumper (non-fatal on failure).
        var hasBumper = false
        var bumperURL: URL?
        var shouldKeepBumperCache = false
        do {
            bumperURL = try await appendEndBumper(
                to: composition,
                videoTracks: videoTracks,
                renderSize: resolution,
                fps: plan.outputFPS
            )
            hasBumper = true
        } catch {
            hasBumper = false
        }
        defer {
            if let bumperURL, !shouldKeepBumperCache {
                try? FileManager.default.removeItem(at: bumperURL)
            }
        }
        try Task.checkCancellation()
        progressHandler(0.30)

        // Step 5: Build video composition AFTER all duration changes.
        // This ensures the instruction covers the full final composition.
        let videoComposition = buildVideoComposition(
            project: project,
            composition: composition,
            videoTracks: videoTracks,
            videoSizes: videoSizes,
            trackTransforms: trackTransforms,
            renderSize: resolution,
            mainContentDuration: mainContentDuration,
            hasBumper: hasBumper,
            outputFPS: plan.outputFPS,
            plan: plan
        )
        try Task.checkCancellation()
        progressHandler(0.35)

        // Step 6: Annotation seam. Wave 5 will provide render items here.
        // The custom compositor receives the empty hook through each instruction.
        progressHandler(0.40)

        // Step 7: Export.
        let outputURL = try await performExport(
            composition: composition,
            videoComposition: videoComposition,
            progressHandler: { sessionProgress in
                progressHandler(0.40 + sessionProgress * 0.60)
            }
        )

        try Task.checkCancellation()
        shouldKeepBumperCache = true
        progressHandler(1.0)
        return outputURL
    }

    // MARK: - Step 1: Load Assets

    private static func loadSources(project: CoreoProject) async throws -> [LoadedSource] {
        var sources: [LoadedSource] = []
        for (index, video) in project.videos.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: ProjectStore().mediaURL(for: video, projectID: project.id))
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw ExportError.compositionFailed("Video \(index) has no video track.")
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioTrack = audioTracks.first
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(transform)
            let displaySize = CGSize(
                width: abs(transformedSize.width),
                height: abs(transformedSize.height)
            )
            let videoTimeRange = try await videoTrack.load(.timeRange)
            let audioTimeRange = try await audioTrack?.load(.timeRange)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

            sources.append(LoadedSource(
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                displaySize: displaySize,
                preferredTransform: transform,
                videoTimeRange: videoTimeRange,
                audioTimeRange: audioTimeRange,
                nominalFrameRate: nominalFrameRate
            ))
        }
        return sources
    }

    // MARK: - Step 2: Build Composition

    private static func buildComposition(
        project: CoreoProject,
        sources: [LoadedSource],
        plan: ExportPlan
    ) async throws -> (
        AVMutableComposition,
        [AVMutableCompositionTrack],
        [CGSize],
        [CGAffineTransform],
        [AVAssetTrack]
    ) {
        let composition = AVMutableComposition()
        var compositionVideoTracks: [AVMutableCompositionTrack] = []
        var videoSizes: [CGSize] = []
        var trackTransforms: [CGAffineTransform] = []
        var sourceVideoTracks: [AVAssetTrack] = []

        for insert in plan.clipInserts {
            try Task.checkCancellation()
            let source = sources[insert.index]

            guard let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ExportError.compositionFailed("Failed to add video track \(insert.index).")
            }

            try compVideoTrack.insertTimeRange(
                insert.sourceRange,
                of: source.videoTrack,
                at: insert.insertTime
            )

            compositionVideoTracks.append(compVideoTrack)
            videoSizes.append(source.displaySize)
            trackTransforms.append(source.preferredTransform)
            sourceVideoTracks.append(source.videoTrack)
        }

        if let audioIndex = plan.audioSourceIndex,
           let source = sources[safe: audioIndex],
           let sourceAudioTrack = source.audioTrack,
           let audioTimeRange = source.audioTimeRange,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           )
        {
            let insertTime = CMTime(
                seconds: max(0, project.videos[audioIndex].syncOffsetSeconds - project.timelineStartSeconds),
                preferredTimescale: timescale
            )
            try compAudioTrack.insertTimeRange(
                audioTimeRange,
                of: sourceAudioTrack,
                at: insertTime
            )
        }

        return (composition, compositionVideoTracks, videoSizes, trackTransforms, sourceVideoTracks)
    }

    // MARK: - Step 3: Speed Segments

    private static func applySpeedSegments(
        to composition: AVMutableComposition,
        plan: ExportPlan,
        sourceVideoTracks: [AVAssetTrack],
        compositionVideoTracks: [AVMutableCompositionTrack]
    ) throws {
        for edit in plan.timelineEdits {
            switch edit {
            case let .scale(range, duration):
                let bounded = CMTimeRangeGetIntersection(
                    range,
                    otherRange: CMTimeRange(start: .zero, duration: composition.duration)
                )
                guard bounded.duration > .zero else { continue }
                composition.scaleTimeRange(bounded, toDuration: duration)
            case let .freeze(clipIndex, compositionTime, sourceTime, frameDuration, holdDuration):
                guard clipIndex < sourceVideoTracks.count,
                      clipIndex < compositionVideoTracks.count else { continue }
                let frameRange = CMTimeRange(start: sourceTime, duration: frameDuration)
                let insertedRange = CMTimeRange(start: compositionTime, duration: frameDuration)
                try compositionVideoTracks[clipIndex].insertTimeRange(
                    frameRange,
                    of: sourceVideoTracks[clipIndex],
                    at: compositionTime
                )
                compositionVideoTracks[clipIndex].scaleTimeRange(
                    insertedRange,
                    toDuration: holdDuration
                )
            case let .gap(clipIndex, range):
                if let clipIndex,
                   clipIndex < compositionVideoTracks.count
                {
                    compositionVideoTracks[clipIndex].insertEmptyTimeRange(range)
                } else {
                    for audioTrack in composition.tracks(withMediaType: .audio) {
                        audioTrack.insertEmptyTimeRange(range)
                    }
                }
            }
        }
    }

    // MARK: - Step 4: End Bumper

    private static func appendEndBumper(
        to composition: AVMutableComposition,
        videoTracks: [AVMutableCompositionTrack],
        renderSize: CGSize,
        fps: Int32
    ) async throws -> URL {
        let bumperURL = try await EndBumperGenerator.generate(resolution: renderSize, fps: fps)
        let bumperAsset = AVURLAsset(url: bumperURL)
        let bumperDuration = try await bumperAsset.load(.duration)
        let bumperVideoTracks = try await bumperAsset.loadTracks(withMediaType: .video)

        guard let bumperVideoTrack = bumperVideoTracks.first else { return bumperURL }

        let insertTime = composition.duration
        let bumperRange = CMTimeRange(start: .zero, duration: bumperDuration)

        for (index, compTrack) in videoTracks.enumerated() {
            if index == 0 {
                try compTrack.insertTimeRange(
                    bumperRange, of: bumperVideoTrack, at: insertTime
                )
            } else {
                compTrack.insertEmptyTimeRange(
                    CMTimeRange(start: insertTime, duration: bumperDuration)
                )
            }
        }

        return bumperURL
    }

    // MARK: - Step 5: Video Composition (Panel Compositor)

    /// Builds the video composition using PanelCompositor for reliable
    /// multi-track rendering with per-panel clipping.
    private static func buildVideoComposition(
        project _: CoreoProject,
        composition: AVMutableComposition,
        videoTracks: [AVMutableCompositionTrack],
        videoSizes: [CGSize],
        trackTransforms: [CGAffineTransform],
        renderSize: CGSize,
        mainContentDuration: CMTime,
        hasBumper: Bool,
        outputFPS: Int32,
        plan: ExportPlan
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: outputFPS)
        videoComposition.customVideoCompositorClass = PanelCompositor.self

        var instructions: [AVVideoCompositionInstructionProtocol] = []

        // Main content: all tracks in their panels.
        var mainPanelConfigs: [PanelCompositionInstruction.PanelConfig] = []
        for (index, track) in videoTracks.enumerated() {
            let videoSize = index < videoSizes.count
                ? videoSizes[index] : CGSize(width: 1920, height: 1080)
            guard let panel = plan.panels.first(where: { $0.index == index }) else {
                continue
            }
            let sourceTransform = index < trackTransforms.count
                ? trackTransforms[index] : .identity

            mainPanelConfigs.append(PanelCompositionInstruction.PanelConfig(
                trackID: track.trackID,
                panelRect: panel.rect,
                videoSize: videoSize,
                sourceTransform: sourceTransform,
                cropRect: panel.cropRect
            ))
        }

        assert(mainPanelConfigs.count == videoTracks.count, "Export layout returned the wrong panel count.")

        let mainInstruction = PanelCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: mainContentDuration),
            panelConfigs: mainPanelConfigs,
            renderSize: renderSize,
            annotationRenderer: EmptyAnnotationFrameRenderer()
        )
        instructions.append(mainInstruction)

        // Bumper: only track 0, full frame, identity transform.
        if hasBumper {
            let bumperStart = mainContentDuration
            let bumperDuration = CMTimeSubtract(composition.duration, mainContentDuration)

            if CMTimeGetSeconds(bumperDuration) > 0 {
                let bumperConfig = PanelCompositionInstruction.PanelConfig(
                    trackID: videoTracks[0].trackID,
                    panelRect: CGRect(origin: .zero, size: renderSize),
                    videoSize: renderSize,
                    sourceTransform: .identity,
                    cropRect: nil
                )
                let bumperInstruction = PanelCompositionInstruction(
                    timeRange: CMTimeRange(start: bumperStart, duration: bumperDuration),
                    panelConfigs: [bumperConfig],
                    renderSize: renderSize,
                    annotationRenderer: EmptyAnnotationFrameRenderer()
                )
                instructions.append(bumperInstruction)
            }
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    // MARK: - Step 7: Export Session

    private static func performExport(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreo_export_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Request background execution time so the export survives app backgrounding.
        final class BackgroundState: @unchecked Sendable {
            var taskID = UIBackgroundTaskIdentifier.invalid
            var expired = false
            var exportSession: AVAssetExportSession?
        }
        let backgroundState = BackgroundState()
        backgroundState.taskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask {
                backgroundState.expired = true
                backgroundState.exportSession?.cancelExport()
                if backgroundState.taskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundState.taskID)
                    backgroundState.taskID = .invalid
                }
            }
        }
        defer {
            if backgroundState.taskID != .invalid {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(backgroundState.taskID)
                }
            }
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("Could not create export session.")
        }
        final class ExportSessionBox: @unchecked Sendable {
            let session: AVAssetExportSession

            init(_ session: AVAssetExportSession) {
                self.session = session
            }

            func cancel() {
                session.cancelExport()
            }
        }
        let exportSessionBox = ExportSessionBox(exportSession)

        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        backgroundState.exportSession = exportSession

        // Progress monitoring.
        let progressTask = Task {
            while !Task.isCancelled {
                progressHandler(Double(exportSession.progress))
                if exportSession.status == .completed
                    || exportSession.status == .failed
                    || exportSession.status == .cancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await withTaskCancellationHandler {
            await exportSession.export()
        } onCancel: {
            exportSessionBox.cancel()
        }
        progressTask.cancel()

        switch exportSession.status {
        case .completed:
            if backgroundState.expired {
                try? FileManager.default.removeItem(at: outputURL)
                throw ExportError.exportFailed(
                    "Export was interrupted in the background. Keep Coreo open during export and try again."
                )
            }
            return outputURL
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        case .failed:
            try? FileManager.default.removeItem(at: outputURL)
            let msg = exportSession.error?.localizedDescription ?? "Unknown error"
            if backgroundState.expired {
                throw ExportError.exportFailed(
                    "Export was interrupted in the background. Keep Coreo open during export and try again."
                )
            }
            throw ExportError.exportFailed(msg)
        default:
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.exportFailed("Unexpected export status.")
        }
    }

    // MARK: - Utilities

    private static func checkDiskSpace(requiredBytes: Int64) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let values = try? tempDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage {
            if free < requiredBytes { throw ExportError.diskFull }
            return
        }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: tempDir.path),
              let free = attrs[.systemFreeSize] as? Int64 else { return }
        if free < requiredBytes { throw ExportError.diskFull }
    }

    private static func makePlanSources(
        project: CoreoProject,
        sources: [LoadedSource]
    ) -> [ExportPlan.SourceVideo] {
        sources.enumerated().map { index, source in
            ExportPlan.SourceVideo(
                index: index,
                syncOffsetSeconds: project.videos[index].syncOffsetSeconds,
                trackTimeRange: source.videoTimeRange,
                displaySize: source.displaySize,
                nominalFrameRate: source.nominalFrameRate,
                hasAudio: source.audioTrack != nil
            )
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
