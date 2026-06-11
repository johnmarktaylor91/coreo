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
// 5. Optionally overlaying annotations via CoreAnimationTool
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
            return "No videos to export."
        case .compositionFailed(let detail):
            return "Composition failed: \(detail)"
        case .exportFailed(let detail):
            return "Export failed: \(detail)"
        case .diskFull:
            return "Not enough disk space to complete the export."
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

/// Handles exporting the multi-angle video composition as a single .mp4 file.
enum ExportEngine {

    private static let exportFPS: Int32 = 30
    private static let timescale: CMTimeScale = 600

    // MARK: - Public

    /// Exports the project as a single composited video file.
    @MainActor
    static func export(
        project: CoreoProject,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        guard !project.videos.isEmpty else {
            throw ExportError.noVideos
        }

        // Sanitize stale indices before using them.
        var project = project
        project.sanitizeIndices()

        try checkDiskSpace(minimumBytes: 500_000_000)
        progressHandler(0.0)

        // Step 1: Load assets.
        let assets = try await loadAssets(project: project)
        progressHandler(0.05)

        // Step 2: Build composition with video + audio tracks.
        let (composition, videoTracks, videoSizes, trackTransforms) = try await buildComposition(
            project: project,
            assets: assets
        )
        progressHandler(0.15)

        // Step 3: Apply speed/hold (if any). Done before video composition
        // so the instruction timeRange reflects the final duration.
        if !project.speedSegments.isEmpty {
            applySpeedSegments(
                to: composition,
                speedSegments: project.speedSegments,
                timelineStart: project.timelineStartSeconds
            )
        }
        progressHandler(0.20)

        // Record the main content duration before bumper.
        let mainContentDuration = composition.duration

        // Step 4: Append end bumper (non-fatal on failure).
        var hasBumper = false
        do {
            try await appendEndBumper(
                to: composition,
                videoTracks: videoTracks,
                renderSize: resolution
            )
            hasBumper = true
        } catch {
            print("End bumper failed, skipping: \(error)")
        }
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
            hasBumper: hasBumper
        )
        progressHandler(0.35)

        // Step 6: Annotation overlay.
        // Note: AVVideoCompositionCoreAnimationTool is incompatible with
        // custom AVVideoCompositing (PanelCompositor). Annotation rendering
        // will be integrated into PanelCompositor in a future task. For now,
        // annotations are skipped during export to ensure split-screen works.
        progressHandler(0.40)

        // Step 7: Export.
        let outputURL = try await performExport(
            composition: composition,
            videoComposition: videoComposition,
            progressHandler: { p in
                progressHandler(0.40 + p * 0.60)
            }
        )

        progressHandler(1.0)
        return outputURL
    }

    // MARK: - Step 1: Load Assets

    private static func loadAssets(project: CoreoProject) async throws -> [AVURLAsset] {
        var assets: [AVURLAsset] = []
        for video in project.videos {
            let asset = AVURLAsset(url: video.localURL)
            _ = try await asset.load(.tracks, .duration)
            assets.append(asset)
        }
        return assets
    }

    // MARK: - Step 2: Build Composition

    private static func buildComposition(
        project: CoreoProject,
        assets: [AVURLAsset]
    ) async throws -> (AVMutableComposition, [AVMutableCompositionTrack], [CGSize], [CGAffineTransform]) {
        let composition = AVMutableComposition()
        var compositionVideoTracks: [AVMutableCompositionTrack] = []
        var videoSizes: [CGSize] = []
        var trackTransforms: [CGAffineTransform] = []

        let timelineStart = project.timelineStartSeconds

        for (index, asset) in assets.enumerated() {
            let assetVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = assetVideoTracks.first else {
                throw ExportError.compositionFailed("Video \(index) has no video track.")
            }

            guard let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ExportError.compositionFailed("Failed to add video track \(index).")
            }

            let syncOffset = index < project.syncOffsets.count
                ? project.syncOffsets[index] : 0.0
            let videoDuration = project.videos[index].durationSeconds
            let assetDuration = CMTime(seconds: videoDuration, preferredTimescale: timescale)
            let insertTime = CMTime(
                seconds: max(0, syncOffset - timelineStart),
                preferredTimescale: timescale
            )
            let sourceTimeRange = CMTimeRange(start: .zero, duration: assetDuration)

            try compVideoTrack.insertTimeRange(
                sourceTimeRange, of: sourceVideoTrack, at: insertTime
            )

            // Natural size accounting for rotation.
            let naturalSize = try await sourceVideoTrack.load(.naturalSize)
            let transform = try await sourceVideoTrack.load(.preferredTransform)
            let transformedSize = naturalSize.applying(transform)
            let correctedSize = CGSize(
                width: abs(transformedSize.width),
                height: abs(transformedSize.height)
            )

            compositionVideoTracks.append(compVideoTrack)
            videoSizes.append(correctedSize)
            trackTransforms.append(transform)

            // Audio: only for the designated source.
            if index == project.audioSourceIndex {
                let assetAudioTracks = try await asset.loadTracks(withMediaType: .audio)
                if let sourceAudioTrack = assetAudioTracks.first,
                   let compAudioTrack = composition.addMutableTrack(
                       withMediaType: .audio,
                       preferredTrackID: kCMPersistentTrackID_Invalid
                   ) {
                    try compAudioTrack.insertTimeRange(
                        sourceTimeRange, of: sourceAudioTrack, at: insertTime
                    )
                }
            }
        }

        return (composition, compositionVideoTracks, videoSizes, trackTransforms)
    }

    // MARK: - Step 3: Speed Segments

    private static func applySpeedSegments(
        to composition: AVMutableComposition,
        speedSegments: [SpeedSegment],
        timelineStart: Double
    ) {
        let sorted = speedSegments.sorted { $0.startTimeSeconds > $1.startTimeSeconds }
        for segment in sorted {
            let segStart = CMTime(
                seconds: segment.startTimeSeconds - timelineStart,
                preferredTimescale: timescale
            )

            if segment.isHold {
                let holdDuration = CMTime(
                    seconds: segment.holdDurationSeconds ?? 1.0,
                    preferredTimescale: timescale
                )
                composition.insertEmptyTimeRange(
                    CMTimeRange(start: segStart, duration: holdDuration)
                )
            } else if segment.rate != 1.0, segment.rate > 0 {
                let segDuration = CMTime(
                    seconds: segment.durationSeconds,
                    preferredTimescale: timescale
                )
                let scaledDuration = CMTime(
                    seconds: segment.durationSeconds / Double(segment.rate),
                    preferredTimescale: timescale
                )
                composition.scaleTimeRange(
                    CMTimeRange(start: segStart, duration: segDuration),
                    toDuration: scaledDuration
                )
            }
        }
    }

    // MARK: - Step 4: End Bumper

    private static func appendEndBumper(
        to composition: AVMutableComposition,
        videoTracks: [AVMutableCompositionTrack],
        renderSize: CGSize
    ) async throws {
        let bumperURL = try await EndBumperGenerator.generate(resolution: renderSize)
        let bumperAsset = AVURLAsset(url: bumperURL)
        let bumperDuration = try await bumperAsset.load(.duration)
        let bumperVideoTracks = try await bumperAsset.loadTracks(withMediaType: .video)

        guard let bumperVideoTrack = bumperVideoTracks.first else { return }

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

        try? FileManager.default.removeItem(at: bumperURL)
    }

    // MARK: - Step 5: Video Composition (Panel Compositor)

    /// Builds the video composition using PanelCompositor for reliable
    /// multi-track rendering with per-panel clipping.
    private static func buildVideoComposition(
        project: CoreoProject,
        composition: AVMutableComposition,
        videoTracks: [AVMutableCompositionTrack],
        videoSizes: [CGSize],
        trackTransforms: [CGAffineTransform],
        renderSize: CGSize,
        mainContentDuration: CMTime,
        hasBumper: Bool
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: exportFPS)
        videoComposition.customVideoCompositorClass = PanelCompositor.self

        // Calculate panel layout.
        let aspectRatios = videoSizes.map { size -> CGFloat in
            guard size.height > 0 else { return 16.0 / 9.0 }
            return size.width / size.height
        }

        let panelRects: [CGRect]
        if let overrides = project.layoutOverrides,
           overrides.panelRects.count == videoTracks.count {
            panelRects = overrides.panelRects.map { rect in
                CGRect(
                    x: rect.origin.x * renderSize.width,
                    y: rect.origin.y * renderSize.height,
                    width: rect.size.width * renderSize.width,
                    height: rect.size.height * renderSize.height
                )
            }
        } else {
            panelRects = LayoutEngine.calculateLayout(
                videoCount: project.videos.count,
                aspectRatios: aspectRatios,
                containerSize: renderSize,
                gap: 4
            )
        }

        var instructions: [AVVideoCompositionInstructionProtocol] = []

        // Main content: all tracks in their panels.
        var mainPanelConfigs: [PanelCompositionInstruction.PanelConfig] = []
        for (index, track) in videoTracks.enumerated() {
            let videoSize = index < videoSizes.count
                ? videoSizes[index] : CGSize(width: 1920, height: 1080)
            let panelRect = index < panelRects.count
                ? panelRects[index] : CGRect(origin: .zero, size: renderSize)
            let sourceTransform = index < trackTransforms.count
                ? trackTransforms[index] : .identity

            mainPanelConfigs.append(PanelCompositionInstruction.PanelConfig(
                trackID: track.trackID,
                panelRect: panelRect,
                videoSize: videoSize,
                sourceTransform: sourceTransform,
                cropRect: project.cropOverrides?[index]
            ))
        }

        let mainInstruction = PanelCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: mainContentDuration),
            panelConfigs: mainPanelConfigs,
            renderSize: renderSize
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
                    renderSize: renderSize
                )
                instructions.append(bumperInstruction)
            }
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    // MARK: - Step 6: Annotation Overlay

    private static func applyAnnotationOverlay(
        to videoComposition: AVMutableVideoComposition,
        annotations: [TimedAnnotation],
        renderSize: CGSize,
        timelineStart: Double,
        timelineDuration: Double
    ) {
        let (parentLayer, videoLayer) = AnnotationCompositor.buildLayers(
            annotations: annotations,
            renderSize: renderSize,
            timelineStart: timelineStart,
            timelineDuration: timelineDuration
        )

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    // MARK: - Step 7: Export Session

    @MainActor
    private static func performExport(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreo_export_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        // Request background execution time so the export survives app backgrounding.
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = await UIApplication.shared.beginBackgroundTask {
            // Expiration handler — system is about to suspend us.
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.exportFailed("Could not create export session.")
        }

        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // Progress monitoring.
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progressHandler(Double(exportSession.progress))
                if exportSession.status == .completed
                    || exportSession.status == .failed
                    || exportSession.status == .cancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await exportSession.export()
        progressTask.cancel()

        switch exportSession.status {
        case .completed:
            return outputURL
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        case .failed:
            try? FileManager.default.removeItem(at: outputURL)
            let msg = exportSession.error?.localizedDescription ?? "Unknown error"
            throw ExportError.exportFailed(msg)
        default:
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.exportFailed("Unexpected export status.")
        }
    }

    // MARK: - Utilities

    private static func checkDiskSpace(minimumBytes: Int64) throws {
        let tempDir = FileManager.default.temporaryDirectory
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: tempDir.path
        ), let free = attrs[.systemFreeSize] as? Int64 else { return }
        if free < minimumBytes { throw ExportError.diskFull }
    }
}
