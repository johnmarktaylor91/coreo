// LayoutEngineSnapshotTests.swift
// CoreoTests
//
// Snapshot references are valid only on iPhone 17 Pro, OS=26.5.

@testable import Coreo
import SnapshotTesting
import XCTest

final class LayoutEngineSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record = .never

    /// Runs each snapshot under a fixed light-mode trait collection.
    override func invokeTest() {
        withSnapshotTesting(record: recordMode) {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                super.invokeTest()
            }
        }
    }

    /// Snapshots stable text dumps for 1-6 video mixed-aspect layouts.
    func testOneThroughSixMixedAspectRatioLayouts() {
        let dump = LayoutSnapshotFormatter.dump(scenarios: [
            .init(
                name: "1-wide",
                videoCount: 1,
                aspectRatios: [16.0 / 9.0],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "2-wide-tall",
                videoCount: 2,
                aspectRatios: [16.0 / 9.0, 9.0 / 16.0],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "3-mixed",
                videoCount: 3,
                aspectRatios: [16.0 / 9.0, 4.0 / 3.0, 9.0 / 16.0],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "4-grid-mixed",
                videoCount: 4,
                aspectRatios: [16.0 / 9.0, 1, 4.0 / 3.0, 9.0 / 16.0],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "5-row-candidate",
                videoCount: 5,
                aspectRatios: [16.0 / 9.0, 16.0 / 9.0, 4.0 / 3.0, 1, 9.0 / 16.0],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "6-regression",
                videoCount: 6,
                aspectRatios: [16.0 / 9.0, 4.0 / 3.0, 1, 9.0 / 16.0, 3.0 / 4.0, 2],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            )
        ])

        assertSnapshot(of: dump, as: .lines, named: "one-through-six-mixed-aspects")
    }

    /// Snapshots stable text dumps for invalid layout inputs.
    func testDegenerateLayoutInputs() {
        let dump = LayoutSnapshotFormatter.dump(scenarios: [
            .init(
                name: "zero-count",
                videoCount: 0,
                aspectRatios: [],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "seven-count",
                videoCount: 7,
                aspectRatios: Array(repeating: 16.0 / 9.0, count: 7),
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "mismatched-aspect-count",
                videoCount: 3,
                aspectRatios: [16.0 / 9.0, 16.0 / 9.0],
                containerSize: CGSize(width: 1000, height: 600),
                gap: 4
            ),
            .init(
                name: "zero-width-container",
                videoCount: 2,
                aspectRatios: [16.0 / 9.0, 16.0 / 9.0],
                containerSize: CGSize(width: 0, height: 600),
                gap: 4
            )
        ])

        assertSnapshot(of: dump, as: .lines, named: "degenerate-inputs")
    }
}

private enum LayoutSnapshotFormatter {
    /// Inputs needed to compute and label a layout snapshot case.
    struct Scenario {
        let name: String
        let videoCount: Int
        let aspectRatios: [CGFloat]
        let containerSize: CGSize
        let gap: CGFloat
    }

    /// Formats all scenarios into one deterministic text snapshot.
    static func dump(scenarios: [Scenario]) -> String {
        scenarios
            .map(dump)
            .joined(separator: "\n\n")
    }

    /// Formats one scenario into a deterministic text block.
    private static func dump(scenario: Scenario) -> String {
        let rects = LayoutEngine.calculateLayout(
            videoCount: scenario.videoCount,
            aspectRatios: scenario.aspectRatios,
            containerSize: scenario.containerSize,
            gap: scenario.gap
        )
        var lines = [
            "scenario: \(scenario.name)",
            "canvas: \(format(size: scenario.containerSize))",
            "gap: \(format(scenario.gap))",
            "videoCount: \(scenario.videoCount)",
            "aspectRatios: \(scenario.aspectRatios.map(format).joined(separator: ", "))",
            "rectCount: \(rects.count)"
        ]
        let sortedRects = rects.enumerated().sorted { lhs, rhs in
            if lhs.element.minY == rhs.element.minY {
                return lhs.element.minX < rhs.element.minX
            }
            return lhs.element.minY < rhs.element.minY
        }
        lines.append(contentsOf: sortedRects.map { index, rect in
            "panel[\(index)]: \(format(rect: rect))"
        })
        return lines.joined(separator: "\n")
    }

    /// Formats a rectangle with fixed decimal precision.
    private static func format(rect: CGRect) -> String {
        "x:\(format(rect.minX)) y:\(format(rect.minY)) w:\(format(rect.width)) h:\(format(rect.height))"
    }

    /// Formats a size with fixed decimal precision.
    private static func format(size: CGSize) -> String {
        "w:\(format(size.width)) h:\(format(size.height))"
    }

    /// Formats a scalar with fixed decimal precision.
    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
