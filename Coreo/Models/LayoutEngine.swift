// LayoutEngine.swift
// Coreo
//
// Calculates optimal split-screen panel layouts for 1-6 videos.
// Evaluates candidate row configurations and picks the one that
// maximizes the total visible (non-letterboxed) video area.

import Foundation

/// Pure-function layout calculator for multi-angle video split-screen grids.
enum LayoutEngine {
    /// Calculates the optimal panel layout for the given videos.
    ///
    /// Evaluates multiple row configurations and returns the one that maximizes
    /// total visible video area (minimizing letterboxing/pillarboxing).
    ///
    /// - Parameters:
    ///   - videoCount: Number of videos (1-6). Values outside this range return an empty array.
    ///   - aspectRatios: Width/height ratio of each video. Must have `videoCount` elements.
    ///   - containerSize: The available container size in points.
    ///   - gap: Gap between panels in points. Defaults to 4.
    /// - Returns: Array of CGRect frames in points for each panel, ordered by video index.
    static func calculateLayout(
        videoCount: Int,
        aspectRatios: [CGFloat],
        containerSize: CGSize,
        gap: CGFloat = 4
    ) -> [CGRect] {
        guard videoCount >= 1, videoCount <= 6 else { return [] }
        guard aspectRatios.count == videoCount else { return [] }
        guard containerSize.width > 0, containerSize.height > 0 else { return [] }

        // Single video: full container.
        if videoCount == 1 {
            return [CGRect(origin: .zero, size: containerSize)]
        }

        let candidates = layoutVariants(for: videoCount).filter { rowConfig in
            rowConfig.reduce(0, +) == videoCount
        }
        var bestRects: [CGRect] = []
        var bestScore: CGFloat = -1

        for rowConfig in candidates {
            let rects = rectsForConfig(rowConfig, containerSize: containerSize, gap: gap)
            let score = totalVisibleArea(rects: rects, aspectRatios: aspectRatios)
            if score > bestScore {
                bestScore = score
                bestRects = rects
            }
        }

        return bestRects
    }

    // MARK: - Private Helpers

    /// Returns the candidate row configurations for the given video count.
    ///
    /// Each configuration is an array of integers where each integer is the
    /// number of panels in that row. For example, [2, 1] means 2 panels on
    /// the top row and 1 on the bottom.
    private static func layoutVariants(for count: Int) -> [[Int]] {
        switch count {
        case 2:
            return [[2]]           // side by side
        case 3:
            return [[1, 2], [2, 1]]
        case 4:
            return [[2, 2]]        // 2x2 grid
        case 5:
            return [[2, 3], [3, 2]]
        case 6:
            return [[3, 3], [2, 2, 2]]
        default:
            return []
        }
    }

    /// Calculates panel rectangles for a given row configuration.
    ///
    /// Panels within each row are equally sized. Rows share the container
    /// height equally. Gaps are applied between panels and between rows.
    private static func rectsForConfig(
        _ rowConfig: [Int],
        containerSize: CGSize,
        gap: CGFloat
    ) -> [CGRect] {
        let rowCount = CGFloat(rowConfig.count)
        guard rowCount > 0 else { return [] }
        let totalVerticalGap = gap * (rowCount - 1)
        let rowHeight = max(1, (containerSize.height - totalVerticalGap) / rowCount)

        var rects: [CGRect] = []
        var currentY: CGFloat = 0

        for rowIndex in 0..<rowConfig.count {
            let panelsInRow = CGFloat(rowConfig[rowIndex])
            guard panelsInRow > 0 else { continue }
            let totalHorizontalGap = gap * (panelsInRow - 1)
            let panelWidth = max(1, (containerSize.width - totalHorizontalGap) / panelsInRow)

            var currentX: CGFloat = 0

            for _ in 0..<rowConfig[rowIndex] {
                rects.append(CGRect(
                    x: currentX,
                    y: currentY,
                    width: panelWidth,
                    height: rowHeight
                ))
                currentX += panelWidth + gap
            }

            currentY += rowHeight + gap
        }

        return rects
    }

    /// Scores a layout by summing the visible (non-letterboxed) video area across all panels.
    ///
    /// For each panel, the video is aspect-fitted into the panel. The visible area
    /// is the area of the fitted video, not the full panel. A higher score means
    /// more of the container is occupied by actual video content.
    private static func totalVisibleArea(
        rects: [CGRect],
        aspectRatios: [CGFloat]
    ) -> CGFloat {
        var totalArea: CGFloat = 0

        for i in 0..<min(rects.count, aspectRatios.count) {
            let panel = rects[i]
            let videoAR = aspectRatios[i]
            let panelAR = panel.width / panel.height

            let visibleWidth: CGFloat
            let visibleHeight: CGFloat

            if videoAR > panelAR {
                // Video is wider than panel — fit to width, letterbox top/bottom
                visibleWidth = panel.width
                visibleHeight = panel.width / videoAR
            } else {
                // Video is taller than panel — fit to height, pillarbox left/right
                visibleHeight = panel.height
                visibleWidth = panel.height * videoAR
            }

            totalArea += visibleWidth * visibleHeight
        }

        return totalArea
    }
}
