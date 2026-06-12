// ExportPlan.swift
// Coreo
//
// Pure export planning helpers. This file intentionally avoids
// AVAssetExportSession so timeline math and layout choices can be tested
// without running an encode.

import AVFoundation
import Foundation

/// Pure description of the export pipeline's timeline, layout, and media choices.
struct ExportPlan {
    /// Information about one source video track.
    struct SourceVideo {
        /// Stable index in `CoreoProject.videos`.
        let index: Int
        /// Timeline offset in seconds relative to the reference angle.
        let syncOffsetSeconds: Double
        /// Actual source video track time range.
        let trackTimeRange: CMTimeRange
        /// Display-oriented source size.
        let displaySize: CGSize
        /// Nominal source frame rate.
        let nominalFrameRate: Float
        /// Whether this clip has an audio track available for fallback selection.
        let hasAudio: Bool
    }

    /// Planned insertion for one video track.
    struct ClipInsert {
        /// Stable index in `CoreoProject.videos`.
        let index: Int
        /// Source track range to insert.
        let sourceRange: CMTimeRange
        /// Composition time where this clip starts.
        let insertTime: CMTime
        /// Single-frame source duration used for holds.
        let frameDuration: CMTime
    }

    /// Planned speed or freeze-frame operation.
    enum TimelineEdit: Equatable {
        /// Scale an existing composition time range to a new duration.
        case scale(range: CMTimeRange, toDuration: CMTime)
        /// Insert and scale a source frame for a single clip.
        case freeze(
            clipIndex: Int,
            compositionTime: CMTime,
            sourceTime: CMTime,
            frameDuration: CMTime,
            holdDuration: CMTime
        )
        /// Insert silence or visual emptiness for a track that has no frame at a hold.
        case gap(clipIndex: Int?, range: CMTimeRange)
    }

    /// Geometry for one rendered panel.
    struct Panel {
        /// Stable index in `CoreoProject.videos`.
        let index: Int
        /// Panel rectangle in render coordinates.
        let rect: CGRect
        /// Optional normalized crop rectangle.
        let cropRect: CGRect?
    }

    /// Insert ranges for source clips.
    let clipInserts: [ClipInsert]
    /// Timeline edits ordered from latest to earliest.
    let timelineEdits: [TimelineEdit]
    /// Panel rectangles for the export render size.
    let panels: [Panel]
    /// Selected audio clip index, or nil for video-only export.
    let audioSourceIndex: Int?
    /// Estimated bytes required for the encoded export.
    let estimatedOutputBytes: Int64
    /// Output frames per second.
    let outputFPS: Int32
    /// Main content duration after speed and hold mapping, before the bumper.
    let mappedContentDurationSeconds: Double

    private static let timescale: CMTimeScale = 600
    private static let previewReferenceWidth: CGFloat = 390
    private static let previewGap: CGFloat = 4
    private static let bumperDurationSeconds: Double = 1

    /// Creates a pure export plan from project and source-track metadata.
    ///
    /// - Parameters:
    ///   - project: Project to export.
    ///   - sources: Source-track metadata in project video order.
    ///   - renderSize: Output render size in pixels.
    /// - Throws: `ExportError` if project arrays are inconsistent.
    init(project: CoreoProject, sources: [SourceVideo], renderSize: CGSize) throws {
        try Self.validateProject(project, sources: sources)
        let planSources = sources.map { source in
            SourceVideo(
                index: source.index,
                syncOffsetSeconds: project.videos[source.index].syncOffsetSeconds,
                trackTimeRange: source.trackTimeRange,
                displaySize: source.displaySize,
                nominalFrameRate: source.nominalFrameRate,
                hasAudio: source.hasAudio
            )
        }

        let timelineStart = project.timelineStartSeconds
        clipInserts = Self.makeClipInserts(
            sources: planSources,
            timelineStart: timelineStart
        )
        timelineEdits = Self.makeTimelineEdits(
            segments: project.speedSegments,
            sources: planSources,
            timelineStart: timelineStart
        )
        panels = Self.makePanels(
            project: project,
            sources: planSources,
            renderSize: renderSize
        )
        audioSourceIndex = Self.chooseAudioSource(
            referenceIndex: project.referenceVideoIndex,
            sources: planSources
        )
        mappedContentDurationSeconds = Self.mappedDuration(
            timelineStart: timelineStart,
            timelineEnd: project.timelineEndSeconds,
            segments: project.speedSegments
        )
        outputFPS = Self.chooseOutputFPS(sources: planSources)
        estimatedOutputBytes = Self.estimateOutputBytes(
            durationSeconds: mappedContentDurationSeconds + Self.bumperDurationSeconds,
            renderSize: renderSize
        )
    }

    /// Maps an original timeline time to post-speed export content time.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Timeline time before speed or hold edits.
    ///   - timelineStart: Timeline start time.
    ///   - segments: Speed and hold segments.
    /// - Returns: Export content time before bumper.
    static func exportTime(
        for timelineSeconds: Double,
        timelineStart: Double,
        segments: [SpeedSegment]
    ) -> Double {
        TimeMapper(clips: [], speedSegments: segments)
            .exportTime(forTimeline: timelineSeconds, timelineStart: timelineStart)
    }

    /// Computes the normalized top-left crop rect in CIImage coordinates.
    ///
    /// - Parameters:
    ///   - cropRect: Normalized top-left-origin crop rectangle.
    ///   - extent: Current image extent.
    /// - Returns: Crop rectangle in CIImage coordinates.
    static func ciCropRect(for cropRect: CGRect, extent: CGRect) -> CGRect {
        CropGeometry.ciCropRect(for: cropRect, extent: extent) ?? extent
    }

    /// Computes the aspect-fit placement for content inside a panel.
    ///
    /// - Parameters:
    ///   - contentExtent: Source content extent after crop.
    ///   - panelRect: Destination panel rectangle in CI coordinates.
    /// - Returns: Scale and offset to place the source content in the panel.
    static func aspectFitTransform(
        contentExtent: CGRect,
        panelRect: CGRect
    ) -> (scale: CGFloat, offset: CGPoint) {
        let scaleX = panelRect.width / contentExtent.width
        let scaleY = panelRect.height / contentExtent.height
        let scale = min(scaleX, scaleY)
        let scaledWidth = contentExtent.width * scale
        let scaledHeight = contentExtent.height * scale
        return (
            scale,
            CGPoint(
                x: panelRect.origin.x + (panelRect.width - scaledWidth) / 2,
                y: panelRect.origin.y + (panelRect.height - scaledHeight) / 2
            )
        )
    }

    /// Chooses the export frame rate from source tracks.
    ///
    /// - Parameter sources: Source-track metadata.
    /// - Returns: Maximum source FPS capped at 60, with 30 as the floor.
    static func chooseOutputFPS(sources: [SourceVideo]) -> Int32 {
        let maxFPS = sources
            .map(\.nominalFrameRate)
            .filter { $0.isFinite && $0 > 0 }
            .max() ?? 30
        if maxFPS > 30 {
            return 60
        }
        return 30
    }

    /// Estimates output file size for disk preflight.
    ///
    /// - Parameters:
    ///   - durationSeconds: Final export duration including bumper.
    ///   - renderSize: Output render size.
    /// - Returns: Estimated bytes with safety margin.
    static func estimateOutputBytes(durationSeconds: Double, renderSize: CGSize) -> Int64 {
        let pixels = max(renderSize.width * renderSize.height, 1)
        let fullHDPixels = CGFloat(1920 * 1080)
        let bitrate = max(4_000_000, 12_000_000 * Double(pixels / fullHDPixels))
        return Int64((durationSeconds * bitrate / 8 * 1.5).rounded(.up))
    }

    private static func validateProject(
        _ project: CoreoProject,
        sources: [SourceVideo]
    ) throws {
        guard project.videos.count == sources.count else {
            throw ExportError.compositionFailed("Loaded source count does not match project videos.")
        }
        guard project.videos.indices.contains(project.referenceVideoIndex) else {
            throw ExportError.compositionFailed("Reference video index is invalid.")
        }
        guard sources.allSatisfy({ project.videos.indices.contains($0.index) }) else {
            throw ExportError.compositionFailed("Source video index is invalid.")
        }
    }

    private static func makeClipInserts(
        sources: [SourceVideo],
        timelineStart: Double
    ) -> [ClipInsert] {
        sources.map { source in
            let insertTime = CMTime(
                seconds: max(0, source.syncOffsetSeconds - timelineStart),
                preferredTimescale: timescale
            )
            return ClipInsert(
                index: source.index,
                sourceRange: source.trackTimeRange,
                insertTime: insertTime,
                frameDuration: frameDuration(for: source)
            )
        }
    }

    private static func makeTimelineEdits(
        segments: [SpeedSegment],
        sources: [SourceVideo],
        timelineStart: Double
    ) -> [TimelineEdit] {
        var edits: [TimelineEdit] = []
        for segment in segments.sorted(by: { $0.startTimeSeconds > $1.startTimeSeconds }) {
            let start = CMTime(
                seconds: segment.startTimeSeconds - timelineStart,
                preferredTimescale: timescale
            )
            if segment.isHold {
                let holdDuration = CMTime(
                    seconds: segment.holdDurationSeconds ?? 1,
                    preferredTimescale: timescale
                )
                for source in sources {
                    let sourceSeconds = segment.startTimeSeconds - source.syncOffsetSeconds
                    if sourceSeconds >= 0,
                       sourceSeconds <= CMTimeGetSeconds(source.trackTimeRange.duration) {
                        edits.append(.freeze(
                            clipIndex: source.index,
                            compositionTime: start,
                            sourceTime: CMTimeAdd(
                                source.trackTimeRange.start,
                                CMTime(seconds: sourceSeconds, preferredTimescale: timescale)
                            ),
                            frameDuration: frameDuration(for: source),
                            holdDuration: holdDuration
                        ))
                    } else {
                        edits.append(.gap(
                            clipIndex: source.index,
                            range: CMTimeRange(start: start, duration: holdDuration)
                        ))
                    }
                }
                edits.append(.gap(clipIndex: nil, range: CMTimeRange(start: start, duration: holdDuration)))
            } else if segment.rate > 0, segment.rate != 1 {
                let duration = CMTime(seconds: segment.durationSeconds, preferredTimescale: timescale)
                let mapped = CMTime(
                    seconds: segment.durationSeconds / Double(segment.rate),
                    preferredTimescale: timescale
                )
                edits.append(.scale(range: CMTimeRange(start: start, duration: duration), toDuration: mapped))
            }
        }
        return edits
    }

    private static func makePanels(
        project: CoreoProject,
        sources: [SourceVideo],
        renderSize: CGSize
    ) -> [Panel] {
        let rects: [CGRect]
        let manualOverrides = project.videos.compactMap(\.panelRectOverride)
        if manualOverrides.count == sources.count {
            rects = manualOverrides.map { rect in
                CGRect(
                    x: rect.origin.x * renderSize.width,
                    y: rect.origin.y * renderSize.height,
                    width: rect.size.width * renderSize.width,
                    height: rect.size.height * renderSize.height
                )
            }
        } else {
            let previewHeight = previewReferenceWidth * renderSize.height / renderSize.width
            let previewSize = CGSize(width: previewReferenceWidth, height: previewHeight)
            let aspectRatios = sources.map { source -> CGFloat in
                guard source.displaySize.height > 0 else { return 16 / 9 }
                return source.displaySize.width / source.displaySize.height
            }
            let previewRects = LayoutEngine.calculateLayout(
                videoCount: sources.count,
                aspectRatios: aspectRatios,
                containerSize: previewSize,
                gap: previewGap
            )
            let scaleX = renderSize.width / previewSize.width
            let scaleY = renderSize.height / previewSize.height
            rects = previewRects.map { rect in
                CGRect(
                    x: rect.origin.x * scaleX,
                    y: rect.origin.y * scaleY,
                    width: rect.width * scaleX,
                    height: rect.height * scaleY
                )
            }
        }

        return sources.enumerated().compactMap { offset, source in
            guard offset < rects.count else { return nil }
            return Panel(
                index: source.index,
                rect: rects[offset],
                cropRect: project.videos[source.index].effectiveCropRect
            )
        }
    }

    private static func chooseAudioSource(
        referenceIndex: Int,
        sources: [SourceVideo]
    ) -> Int? {
        if sources.contains(where: { $0.index == referenceIndex && $0.hasAudio }) {
            return referenceIndex
        }
        return sources.first(where: { $0.hasAudio })?.index
    }

    private static func mappedDuration(
        timelineStart: Double,
        timelineEnd: Double,
        segments: [SpeedSegment]
    ) -> Double {
        exportTime(for: timelineEnd, timelineStart: timelineStart, segments: segments)
    }

    private static func frameDuration(for source: SourceVideo) -> CMTime {
        let fps = source.nominalFrameRate.isFinite && source.nominalFrameRate > 0
            ? min(max(source.nominalFrameRate, 1), 60)
            : 30
        return CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
    }
}
