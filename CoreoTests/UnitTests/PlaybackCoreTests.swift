// PlaybackCoreTests.swift
// CoreoTests
//
// Unit coverage for Wave 4 playback-core pure policy.

import CoreGraphics
@testable import Coreo
import XCTest

/// Tests for playback synchronization planning and timeline math.
final class PlaybackCoreTests: XCTestCase {
    /// PlayerSyncPlan keeps a late-starting clip inactive until its sync window opens.
    func testPlayerSyncPlanLateStartActivationWindow() {
        let firstID = UUID()
        let secondID = UUID()
        let mapper = TimeMapper(clips: [
            .init(id: firstID, syncOffsetSeconds: 0, durationSeconds: 10),
            .init(id: secondID, syncOffsetSeconds: 3, durationSeconds: 10)
        ])

        let before = PlayerSyncPlan.make(timelineSeconds: 2, mapper: mapper, rate: 1)
        XCTAssertEqual(before.states[0], .active(clipSeconds: 2, rate: 1))
        XCTAssertEqual(before.states[1], .inactive(clipSeconds: 0, reason: .beforeStart(startsInSeconds: 1)))

        let atStart = PlayerSyncPlan.make(timelineSeconds: 3, mapper: mapper, rate: 1)
        XCTAssertEqual(atStart.states[1], .active(clipSeconds: 0, rate: 1))
    }

    /// PlayerSyncPlan respects per-video trims through TimeMapper.
    func testPlayerSyncPlanRespectsTrimRange() {
        let clipID = UUID()
        let mapper = TimeMapper(clips: [
            .init(
                id: clipID,
                syncOffsetSeconds: 2,
                durationSeconds: 20,
                trimStartSeconds: 4,
                trimDurationSeconds: 6
            )
        ])

        let beforeTrim = PlayerSyncPlan.make(timelineSeconds: 5, mapper: mapper, rate: 1)
        XCTAssertEqual(beforeTrim.states[0], .inactive(clipSeconds: 4, reason: .beforeStart(startsInSeconds: 1)))

        let insideTrim = PlayerSyncPlan.make(timelineSeconds: 8, mapper: mapper, rate: 0.5)
        XCTAssertEqual(insideTrim.states[0], .active(clipSeconds: 6, rate: 0.5))

        let afterTrim = PlayerSyncPlan.make(timelineSeconds: 13, mapper: mapper, rate: 1)
        XCTAssertEqual(afterTrim.states[0], .inactive(clipSeconds: 10, reason: .afterEnd))
    }

    /// Hold crossing detection triggers on boundary crossing rather than containment.
    func testHoldCrossingDetectionSchedulesResume() throws {
        let hold = SpeedSegment(
            id: UUID(),
            startTimeSeconds: 5,
            durationSeconds: 0.01,
            rate: 0,
            holdDurationSeconds: 2
        )
        let event = HoldPlaybackCoordinator().crossedHold(
            previousSeconds: 4.98,
            currentSeconds: 5.04,
            speedMap: SpeedMap(segments: [hold]),
            playbackRate: 2
        )

        let unwrappedEvent = try XCTUnwrap(event)
        XCTAssertEqual(unwrappedEvent.holdTimelineSeconds, 5)
        XCTAssertEqual(unwrappedEvent.resumeTimelineSeconds, 5.01, accuracy: 0.000_001)
        XCTAssertEqual(unwrappedEvent.wallDurationSeconds, 1)
    }

    /// SpeedMap caches sorted order at construction and preserves latest-start precedence.
    func testSpeedMapLatestStartPrecedenceWithCachedSort() {
        let broad = SpeedSegment(id: UUID(), startTimeSeconds: 1, durationSeconds: 8, rate: 0.5)
        let nested = SpeedSegment(id: UUID(), startTimeSeconds: 3, durationSeconds: 2, rate: 2)
        let map = SpeedMap(segments: [broad, nested])

        XCTAssertEqual(map.rate(at: 2), 0.5)
        XCTAssertEqual(map.rate(at: 4), 2)
        XCTAssertEqual(map.sortedSegments.map(\.id), [broad.id, nested.id])
    }

    /// TimelineCoordinateMapper keeps rendering and gesture conversion round-trippable with insets.
    func testTimelineCoordinateMapperRoundTripWithInsets() {
        let mapper = TimelineCoordinateMapper(startSeconds: -2, endSeconds: 10, leadingInset: 8, trailingInset: 8)
        let mappedX = mapper.x(for: 4, totalWidth: 316)
        XCTAssertEqual(mappedX, 158, accuracy: 0.000_001)
        XCTAssertEqual(mapper.seconds(forX: mappedX, totalWidth: 316), 4, accuracy: 0.000_001)
        XCTAssertEqual(mapper.seconds(forX: 0, totalWidth: 316), -2, accuracy: 0.000_001)
        XCTAssertEqual(mapper.seconds(forX: 316, totalWidth: 316), 10, accuracy: 0.000_001)
    }

    /// Offset nudge math round-trips through TimeMapper clip mapping.
    func testManualSyncNudgeMathRoundTrip() throws {
        let id = UUID()
        let original = VideoAsset(
            id: id,
            relativePath: "media/a.mov",
            durationSeconds: 10,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 48000,
            thumbnailData: nil,
            syncOffsetSeconds: 1
        )
        var nudged = original
        nudged.syncOffsetSeconds += 1.0 / 30.0
        let mapper = TimeMapper(clips: [.init(video: nudged)])
        let timeline = try XCTUnwrap(mapper.timelineTime(forClip: 2, clipID: id))
        let clipTime = try XCTUnwrap(mapper.clipTime(forTimeline: timeline, clipID: id))

        XCTAssertEqual(timeline, 2 + 1 + 1.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(clipTime, 2, accuracy: 0.000_001)
    }
}
