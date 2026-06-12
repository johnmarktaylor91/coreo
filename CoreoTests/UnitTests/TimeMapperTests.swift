// TimeMapperTests.swift
// CoreoTests

import CoreGraphics
@testable import Coreo
import XCTest

final class TimeMapperTests: XCTestCase {
    func testTimelineToClipAndBackWithOffset() throws {
        let clipID = UUID()
        let mapper = TimeMapper(clips: [
            TimeMapper.Clip(id: clipID, syncOffsetSeconds: 3, durationSeconds: 20)
        ])

        let clipTime = try XCTUnwrap(mapper.clipTime(forTimeline: 8, clipID: clipID))
        let timelineTime = try XCTUnwrap(mapper.timelineTime(forClip: clipTime, clipID: clipID))

        XCTAssertEqual(clipTime, 5, accuracy: 0.001)
        XCTAssertEqual(timelineTime, 8, accuracy: 0.001)
    }

    func testClipMappingClampsToTrimRange() throws {
        let clipID = UUID()
        let mapper = TimeMapper(clips: [
            TimeMapper.Clip(
                id: clipID,
                syncOffsetSeconds: -2,
                durationSeconds: 20,
                trimStartSeconds: 4,
                trimDurationSeconds: 6
            )
        ])

        XCTAssertFalse(mapper.isClipActive(atTimeline: 1, clipID: clipID))
        XCTAssertTrue(mapper.isClipActive(atTimeline: 2, clipID: clipID))
        XCTAssertEqual(try XCTUnwrap(mapper.clipTime(forTimeline: -10, clipID: clipID)), 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(mapper.timelineTime(forClip: 99, clipID: clipID)), 8, accuracy: 0.001)
    }

    func testExportMappingAtSpeedSegmentBoundaries() {
        let mapper = TimeMapper(
            clips: [TimeMapper.Clip(syncOffsetSeconds: 0, durationSeconds: 30)],
            speedSegments: [makeSegment(start: 10, duration: 10, rate: 0.5)]
        )

        XCTAssertEqual(mapper.exportTime(forTimeline: 10), 10, accuracy: 0.001)
        XCTAssertEqual(mapper.exportTime(forTimeline: 15), 20, accuracy: 0.001)
        XCTAssertEqual(mapper.exportTime(forTimeline: 20), 30, accuracy: 0.001)
        XCTAssertEqual(mapper.timelineTime(forExport: 20), 15, accuracy: 0.001)
    }

    func testHoldMapsOutputIntervalToHoldStart() {
        let mapper = TimeMapper(
            clips: [TimeMapper.Clip(syncOffsetSeconds: 0, durationSeconds: 30)],
            speedSegments: [makeSegment(start: 5, duration: 0.01, rate: 0, hold: 2)]
        )

        XCTAssertEqual(mapper.exportTime(forTimeline: 10), 12, accuracy: 0.001)
        XCTAssertEqual(mapper.timelineTime(forExport: 5.5), 5, accuracy: 0.001)
        XCTAssertEqual(mapper.timelineTime(forExport: 7.5), 5.5, accuracy: 0.001)
    }

    func testAnnotationVisibilityUsesTimelineTimeFromWarpedExportTime() {
        let mapper = TimeMapper(
            clips: [TimeMapper.Clip(syncOffsetSeconds: 0, durationSeconds: 30)],
            speedSegments: [
                makeSegment(start: 4, duration: 4, rate: 2),
                makeSegment(start: 10, duration: 0.01, rate: 0, hold: 2)
            ]
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: 5,
            durationSeconds: 2,
            isPersistent: false,
            content: .text(TextAnnotation(
                text: "Warped",
                position: CGPoint(x: 0.5, y: 0.5),
                fontSize: 16,
                colorHex: "#FFFFFF"
            )),
            canvasSize: CGSize(width: 390, height: 844),
            createdAt: Date()
        )

        let fadeInExportTime = mapper.exportTime(forTimeline: 5.1)
        let middleExportTime = mapper.exportTime(forTimeline: 6)
        let afterExportTime = mapper.exportTime(forTimeline: 7.1)

        XCTAssertEqual(annotation.opacity(at: mapper.timelineTime(forExport: fadeInExportTime)), 0.5, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: mapper.timelineTime(forExport: middleExportTime)), 1.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: mapper.timelineTime(forExport: afterExportTime)), 0.0, accuracy: 0.001)
        XCTAssertEqual(mapper.timelineTime(forExport: mapper.exportTime(forTimeline: 10) + 1), 10, accuracy: 0.001)
    }

    func testMappedDurationComposesSpeedAndHold() {
        let mapper = TimeMapper(
            clips: [TimeMapper.Clip(syncOffsetSeconds: -2, durationSeconds: 32)],
            speedSegments: [
                makeSegment(start: 10, duration: 10, rate: 0.5),
                makeSegment(start: 25, duration: 0.01, rate: 0, hold: 2)
            ]
        )

        XCTAssertEqual(mapper.mappedDurationSeconds(), 44, accuracy: 0.001)
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
