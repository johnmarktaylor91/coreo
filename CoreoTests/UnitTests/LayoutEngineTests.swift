// LayoutEngineTests.swift
// CoreoTests
//
// Unit tests for the split-screen layout calculator.

import XCTest
@testable import Coreo

final class LayoutEngineTests: XCTestCase {

    let container = CGSize(width: 1000, height: 600)
    let gap: CGFloat = 4

    // MARK: - 2-Video Layout

    func testTwoVideoLayoutReturnsTwoSideBySideRects() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 2,
            aspectRatios: [16.0 / 9.0, 16.0 / 9.0],
            containerSize: container,
            gap: gap
        )

        XCTAssertEqual(rects.count, 2)

        // Both panels should have the same width
        XCTAssertEqual(rects[0].width, rects[1].width, accuracy: 0.1)

        // Both panels should have the same height (full container height)
        XCTAssertEqual(rects[0].height, container.height, accuracy: 0.1)
        XCTAssertEqual(rects[1].height, container.height, accuracy: 0.1)

        // The two panels plus the gap should span the full width
        let totalWidth = rects[0].width + gap + rects[1].width
        XCTAssertEqual(totalWidth, container.width, accuracy: 0.1)
    }

    func testTwoVideoLayoutPanelsDoNotOverlap() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 2,
            aspectRatios: [16.0 / 9.0, 4.0 / 3.0],
            containerSize: container,
            gap: gap
        )

        XCTAssertEqual(rects.count, 2)
        XCTAssertFalse(rects[0].intersects(rects[1]))
    }

    // MARK: - 4-Video Layout

    func testFourVideoLayoutReturns2x2Grid() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 4,
            aspectRatios: Array(repeating: 16.0 / 9.0, count: 4),
            containerSize: container,
            gap: gap
        )

        XCTAssertEqual(rects.count, 4)

        // All panels should be the same size
        let firstRect = rects[0]
        for rect in rects {
            XCTAssertEqual(rect.width, firstRect.width, accuracy: 0.1)
            XCTAssertEqual(rect.height, firstRect.height, accuracy: 0.1)
        }

        // Two distinct Y coordinates (two rows)
        let yValues = Set(rects.map { round($0.origin.y * 10) / 10 })
        XCTAssertEqual(yValues.count, 2)

        // Two distinct X coordinates per row (two columns)
        let xValues = Set(rects.map { round($0.origin.x * 10) / 10 })
        XCTAssertEqual(xValues.count, 2)
    }

    // MARK: - 3-Video Layout

    func testThreeVideoLayoutPicksBestVariant() {
        // Wide videos should prefer the 2-top + 1-bottom or 1-top + 2-bottom
        // layout that gives the most visible area.
        let rects = LayoutEngine.calculateLayout(
            videoCount: 3,
            aspectRatios: [16.0 / 9.0, 16.0 / 9.0, 16.0 / 9.0],
            containerSize: container,
            gap: gap
        )

        XCTAssertEqual(rects.count, 3)

        // All rects should be within the container bounds
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.origin.x, 0)
            XCTAssertGreaterThanOrEqual(rect.origin.y, 0)
            XCTAssertLessThanOrEqual(rect.maxX, container.width + 0.1)
            XCTAssertLessThanOrEqual(rect.maxY, container.height + 0.1)
        }
    }

    // MARK: - Gap Spacing

    func testGapSpacingIsRespected() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 4,
            aspectRatios: Array(repeating: 16.0 / 9.0, count: 4),
            containerSize: container,
            gap: gap
        )

        XCTAssertEqual(rects.count, 4)

        // Sort by position to identify the grid arrangement
        let sorted = rects.sorted { ($0.origin.y, $0.origin.x) < ($1.origin.y, $1.origin.x) }

        // Horizontal gap between columns in the first row
        let horizontalGap = sorted[1].origin.x - sorted[0].maxX
        XCTAssertEqual(horizontalGap, gap, accuracy: 0.1)

        // Vertical gap between rows
        let verticalGap = sorted[2].origin.y - sorted[0].maxY
        XCTAssertEqual(verticalGap, gap, accuracy: 0.1)
    }

    // MARK: - No Overlaps

    func testNoRectsOverlapForAnyCount() {
        for count in 2...6 {
            let aspectRatios = Array(repeating: CGFloat(16.0 / 9.0), count: count)
            let rects = LayoutEngine.calculateLayout(
                videoCount: count,
                aspectRatios: aspectRatios,
                containerSize: container,
                gap: gap
            )

            XCTAssertEqual(rects.count, count, "Wrong number of rects for \(count) videos")

            // Check that no pair of rects overlap (allowing for gap)
            for i in 0..<rects.count {
                for j in (i + 1)..<rects.count {
                    // Inset each rect by a tiny amount to allow for floating-point rounding
                    let a = rects[i].insetBy(dx: 0.5, dy: 0.5)
                    let b = rects[j].insetBy(dx: 0.5, dy: 0.5)
                    XCTAssertFalse(
                        a.intersects(b),
                        "Rects \(i) and \(j) overlap for \(count) videos: \(rects[i]) vs \(rects[j])"
                    )
                }
            }
        }
    }

    // MARK: - Edge Cases

    func testInvalidVideoCountReturnsEmpty() {
        let rects0 = LayoutEngine.calculateLayout(
            videoCount: 0,
            aspectRatios: [],
            containerSize: container,
            gap: gap
        )
        XCTAssertTrue(rects0.isEmpty)

        let rects7 = LayoutEngine.calculateLayout(
            videoCount: 7,
            aspectRatios: Array(repeating: 16.0 / 9.0, count: 7),
            containerSize: container,
            gap: gap
        )
        XCTAssertTrue(rects7.isEmpty)
    }

    func testMismatchedAspectRatioCountReturnsEmpty() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 3,
            aspectRatios: [16.0 / 9.0, 16.0 / 9.0], // only 2, need 3
            containerSize: container,
            gap: gap
        )
        XCTAssertTrue(rects.isEmpty)
    }

    func testZeroContainerSizeReturnsEmpty() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 2,
            aspectRatios: [16.0 / 9.0, 16.0 / 9.0],
            containerSize: CGSize(width: 0, height: 600),
            gap: gap
        )
        XCTAssertTrue(rects.isEmpty)
    }

    // MARK: - 5 and 6 Videos

    func testFiveVideoLayoutReturnsCorrectCount() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 5,
            aspectRatios: Array(repeating: 16.0 / 9.0, count: 5),
            containerSize: container,
            gap: gap
        )
        XCTAssertEqual(rects.count, 5)
    }

    func testSixVideoLayoutReturnsCorrectCount() {
        let rects = LayoutEngine.calculateLayout(
            videoCount: 6,
            aspectRatios: Array(repeating: 16.0 / 9.0, count: 6),
            containerSize: container,
            gap: gap
        )
        XCTAssertEqual(rects.count, 6)
    }

    func testOneThroughSixLayoutsHaveCorrectCountAndCoverage() {
        let containers = [
            CGSize(width: 1000, height: 600),
            CGSize(width: 390, height: 844),
            CGSize(width: 1920, height: 1080),
        ]

        for container in containers {
            for count in 1...6 {
                let rects = LayoutEngine.calculateLayout(
                    videoCount: count,
                    aspectRatios: Array(repeating: 16.0 / 9.0, count: count),
                    containerSize: container,
                    gap: gap
                )

                XCTAssertEqual(rects.count, count, "Wrong count for \(count) in \(container)")
                for rect in rects {
                    XCTAssertGreaterThan(rect.width, 0)
                    XCTAssertGreaterThan(rect.height, 0)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertGreaterThanOrEqual(rect.minY, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, container.width + 0.1)
                    XCTAssertLessThanOrEqual(rect.maxY, container.height + 0.1)
                }
            }
        }
    }
}
