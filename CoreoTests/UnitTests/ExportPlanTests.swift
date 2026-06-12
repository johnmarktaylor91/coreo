// ExportPlanTests.swift
// CoreoTests

import AVFoundation
@testable import Coreo
import XCTest

final class ExportPlanTests: XCTestCase {
    func testHoldsProduceFreezeEditsInsteadOfOnlyGaps() throws {
        var project = makeProject(count: 2, offsets: [0, 0])
        project.speedSegments = [makeSegment(start: 2, duration: 0.01, rate: 0, hold: 1.5)]

        let plan = try ExportPlan(
            project: project,
            sources: makeSources(count: 2, hasAudio: [true, true], offsets: [1, -1]),
            renderSize: CGSize(width: 1920, height: 1080)
        )

        let freezeCount = plan.timelineEdits.filter { edit in
            if case .freeze = edit { return true }
            return false
        }.count
        XCTAssertEqual(freezeCount, 2)
        XCTAssertTrue(plan.timelineEdits.contains { edit in
            if case let .gap(clipIndex, _) = edit { return clipIndex == nil }
            return false
        })
    }

    func testSpeedAndHoldMappingCompose() {
        let slow = makeSegment(start: 10, duration: 10, rate: 0.5)
        let hold = makeSegment(start: 25, duration: 0.01, rate: 0, hold: 2)

        let mapped = ExportPlan.exportTime(
            for: 30,
            timelineStart: 0,
            segments: [slow, hold]
        )

        XCTAssertEqual(mapped, 42, accuracy: 0.001)
    }

    func testCropAndAspectFitMathForMixedResolutionPanel() {
        let extent = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let ciCrop = ExportPlan.ciCropRect(for: crop, extent: extent)
        XCTAssertEqual(ciCrop, CGRect(x: 960, y: 0, width: 960, height: 1080))

        let panel = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let placement = ExportPlan.aspectFitTransform(contentExtent: ciCrop, panelRect: panel)
        XCTAssertEqual(placement.scale, 500.0 / 1080.0, accuracy: 0.0001)
        XCTAssertGreaterThan(placement.offset.x, 0)
        XCTAssertEqual(placement.offset.y, 0, accuracy: 0.0001)
    }

    func testCropGeometryMapsPreviewAndExportFromSameNormalizedRect() throws {
        let crop = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
        let extent = CGRect(x: 0, y: 0, width: 2000, height: 1000)

        let previewRect = CropGeometry.previewContentsRect(for: crop)
        let ciRect = try XCTUnwrap(CropGeometry.ciCropRect(for: crop, extent: extent))

        XCTAssertEqual(previewRect, crop)
        XCTAssertEqual(ciRect.origin.x, 500, accuracy: 0.000_001)
        XCTAssertEqual(ciRect.origin.y, 100, accuracy: 0.000_001)
        XCTAssertEqual(ciRect.width, 1000, accuracy: 0.000_001)
        XCTAssertEqual(ciRect.height, 800, accuracy: 0.000_001)
    }

    func testGapScalesFromPreviewReferenceWidth() throws {
        let project = makeProject(count: 2, offsets: [0, 0])
        let plan = try ExportPlan(
            project: project,
            sources: makeSources(count: 2, hasAudio: [true, true]),
            renderSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(plan.panels.count, 2)
        let gap = plan.panels[1].rect.minX - plan.panels[0].rect.maxX
        XCTAssertEqual(gap, 4 * 1920 / 390, accuracy: 0.001)
    }

    func testAudioFallsBackFromReferenceToFirstAvailableAngle() throws {
        var project = makeProject(count: 3, offsets: [0, 0, 0])
        project.referenceVideoID = project.videos[1].id

        let plan = try ExportPlan(
            project: project,
            sources: makeSources(count: 3, hasAudio: [true, false, true]),
            renderSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(plan.audioSourceIndex, 0)
    }

    func testStableVideoStateProvidesCropAndOffsets() throws {
        var project = makeProject(count: 2, offsets: [1, -1])
        project.videos[1].manualCropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        let plan = try ExportPlan(
            project: project,
            sources: makeSources(count: 2, hasAudio: [true, true]),
            renderSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(plan.clipInserts[0].insertTime.seconds, 2, accuracy: 0.001)
        XCTAssertEqual(plan.clipInserts[1].insertTime.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(plan.panels[1].cropRect, project.videos[1].manualCropRect)
    }

    func testFPSChoiceUsesSourceMaximumCappedAtSixty() {
        let sources = [
            makeSource(index: 0, fps: 24, hasAudio: true),
            makeSource(index: 1, fps: 59.94, hasAudio: true),
            makeSource(index: 2, fps: 120, hasAudio: true)
        ]

        XCTAssertEqual(ExportPlan.chooseOutputFPS(sources: sources), 60)
    }

    func testDiskEstimateScalesWithDurationAndResolution() {
        let short = ExportPlan.estimateOutputBytes(
            durationSeconds: 10,
            renderSize: CGSize(width: 1280, height: 720)
        )
        let long = ExportPlan.estimateOutputBytes(
            durationSeconds: 20,
            renderSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertGreaterThan(long, short)
    }

    private func makeProject(count: Int, offsets: [TimeInterval]) -> CoreoProject {
        let videos = (0 ..< count).map { index in
            VideoAsset(
                id: UUID(),
                relativePath: "media/video-\(index).mov",
                originalFilename: "video-\(index).mov",
                durationSeconds: 10,
                dimensions: CGSize(width: 1920, height: 1080),
                audioBitrate: 128_000,
                audioSampleRate: 48000,
                thumbnailData: nil,
                syncOffsetSeconds: index < offsets.count ? offsets[index] : 0
            )
        }
        return CoreoProject(
            videos: videos,
            referenceVideoID: videos.first?.id,
            audioSourceVideoID: videos.first?.id
        )
    }

    private func makeSources(
        count: Int,
        hasAudio: [Bool],
        offsets: [TimeInterval]? = nil
    ) -> [ExportPlan.SourceVideo] {
        (0 ..< count).map { index in
            makeSource(
                index: index,
                fps: 30,
                hasAudio: hasAudio[index],
                offset: offsets?[index] ?? 0
            )
        }
    }

    private func makeSource(
        index: Int,
        fps: Float,
        hasAudio: Bool,
        offset: TimeInterval = 0
    ) -> ExportPlan.SourceVideo {
        ExportPlan.SourceVideo(
            index: index,
            syncOffsetSeconds: offset,
            trackTimeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 10, preferredTimescale: 600)
            ),
            displaySize: CGSize(width: 1920, height: 1080),
            nominalFrameRate: fps,
            hasAudio: hasAudio
        )
    }

    private func makeSegment(
        start: Double,
        duration: Double,
        rate: Float,
        hold: Double? = nil
    ) -> SpeedSegment {
        SpeedSegment(
            id: UUID(),
            startTimeSeconds: start,
            durationSeconds: duration,
            rate: rate,
            holdDurationSeconds: hold
        )
    }
}
