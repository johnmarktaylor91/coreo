// PlaybackFeatureTests.swift
// CoreoTests
//
// Unit tests for count-in, A-B loop, and scrub snapping policy.

import CoreGraphics
@testable import Coreo
import XCTest

/// Tests playback feature pure policy helpers.
final class PlaybackFeatureTests: XCTestCase {
    /// Count-in starts at three and completes after three ticks.
    func testCountInProgressionCompletesOnce() {
        var machine = CountInStateMachine()
        machine.start()

        XCTAssertEqual(machine.phase, .counting(3))
        XCTAssertFalse(machine.tick())
        XCTAssertEqual(machine.phase, .counting(2))
        XCTAssertFalse(machine.tick())
        XCTAssertEqual(machine.phase, .counting(1))
        XCTAssertTrue(machine.tick())
        XCTAssertEqual(machine.phase, .completed)
        XCTAssertFalse(machine.tick())
    }

    /// Count-in cancellation returns to idle before completion.
    func testCountInCancelMidCount() {
        var machine = CountInStateMachine()
        machine.start()
        XCTAssertFalse(machine.tick())
        machine.cancel()

        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.tick())
    }

    /// A-B loop activation arms, swaps reversed points, rejects tiny loops, and clears.
    func testABLoopSetSwapRejectAndClearTransitions() {
        var loop = LoopPlaybackCoordinator()

        XCTAssertEqual(loop.activate(at: 10), .armed)
        XCTAssertEqual(loop.state, .armed(startSeconds: 10))
        XCTAssertEqual(loop.activate(at: 9.75), .rejectedTooShort)
        XCTAssertEqual(loop.state, .armed(startSeconds: 10))
        XCTAssertEqual(loop.activate(at: 8), .activated)
        XCTAssertEqual(loop.state, .active(LoopRegion(startSeconds: 8, endSeconds: 10)))
        XCTAssertEqual(loop.activate(at: 9), .cleared)
        XCTAssertEqual(loop.state, .cleared)
    }

    /// A-B loop crossing seeks to A only while playback crosses B.
    func testABLoopCrossingDecision() {
        var loop = LoopPlaybackCoordinator()
        _ = loop.activate(at: 4)
        _ = loop.activate(at: 8)

        XCTAssertNil(loop.loopSeekTarget(previousSeconds: 5, currentSeconds: 7.9, isPlaying: true))
        XCTAssertEqual(loop.loopSeekTarget(previousSeconds: 7.9, currentSeconds: 8.1, isPlaying: true), 4)
        XCTAssertNil(loop.loopSeekTarget(previousSeconds: 7.9, currentSeconds: 8.1, isPlaying: false))
        XCTAssertNil(loop.loopSeekTarget(previousSeconds: 8.1, currentSeconds: 7.9, isPlaying: true))
    }

    /// A-B loop clears when timeline duration shrinks before B.
    func testABLoopClearOnDurationShrink() {
        var loop = LoopPlaybackCoordinator()
        _ = loop.activate(at: 4)
        _ = loop.activate(at: 8)

        XCTAssertFalse(loop.clearIfOutOfBounds(durationEndSeconds: 8))
        XCTAssertEqual(loop.state, .active(LoopRegion(startSeconds: 4, endSeconds: 8)))
        XCTAssertTrue(loop.clearIfOutOfBounds(durationEndSeconds: 7.99))
        XCTAssertEqual(loop.state, .cleared)
    }

    /// Snap targets are sorted, deduped, and include timeline bounds plus speed boundaries.
    func testScrubSnapTargetsBuildDedupeOrdering() {
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: 2,
            durationSeconds: 3,
            isPersistent: false,
            content: .text(TextAnnotation(text: "Cue", position: .zero, fontSize: 16, colorHex: "#FFFFFF")),
            createdAt: Date()
        )
        let segment = SpeedSegment(id: UUID(), startTimeSeconds: 2, durationSeconds: 3, rate: 0.5)
        let targets = ScrubSnapTargets.build(
            annotations: [annotation],
            speedSegments: [segment],
            timelineStart: 0,
            timelineEnd: 10
        )

        XCTAssertEqual(targets.times, [0, 2, 5, 10])
    }

    /// Scrub snapping chooses nearest target and picks the earlier target at exact midpoint.
    func testScrubSnapTieBreaksToEarlierTarget() {
        let targets = ScrubSnapTargets(times: [2, 4])

        XCTAssertEqual(targets.snap(candidateSeconds: 3, radiusSeconds: 1), 2)
        XCTAssertEqual(targets.snap(candidateSeconds: 3.2, radiusSeconds: 1.2), 4)
    }

    /// Scrub snapping includes the radius edge and returns original time when disabled.
    func testScrubSnapRadiusInclusivityAndDisabledPath() {
        let targets = ScrubSnapTargets(times: [5])

        XCTAssertEqual(targets.snap(candidateSeconds: 5.5, radiusSeconds: 0.5), 5)
        XCTAssertEqual(targets.snap(candidateSeconds: 5.5, radiusSeconds: 0.49), 5.5)
        XCTAssertEqual(targets.snap(candidateSeconds: 5.1, radiusSeconds: 1, isEnabled: false), 5.1)
    }

    /// Empty snap target sets leave candidates unchanged.
    func testScrubSnapEmptyTargets() {
        let targets = ScrubSnapTargets(times: [])

        XCTAssertEqual(targets.snap(candidateSeconds: 4, radiusSeconds: 1), 4)
    }
}
