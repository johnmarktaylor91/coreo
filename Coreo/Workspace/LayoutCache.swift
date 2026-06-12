// LayoutCache.swift
// Coreo
//
// Memoizes workspace panel layout calculations.

import CoreGraphics
import Foundation

/// Caches `LayoutEngine` results for stable workspace layout inputs.
@MainActor
final class LayoutCache {
    /// Last cache key used for layout.
    private var lastKey: LayoutCacheKey?

    /// Last layout result.
    private var lastRects: [CGRect] = []

    /// Returns panel rects for the given project and container size.
    ///
    /// - Parameters:
    ///   - project: Project containing video dimensions and overrides.
    ///   - containerSize: Available grid size.
    /// - Returns: Panel rectangles in container coordinates.
    func panelRects(project: CoreoProject, containerSize: CGSize) -> [CGRect] {
        let key = LayoutCacheKey(project: project, containerSize: containerSize)
        if key == lastKey {
            return lastRects
        }

        let manualOverrides = project.videos.compactMap(\.panelRectOverride)
        let rects: [CGRect]
        if manualOverrides.count == project.videos.count {
            rects = manualOverrides.map { normalized in
                CGRect(
                    x: normalized.origin.x * containerSize.width,
                    y: normalized.origin.y * containerSize.height,
                    width: normalized.size.width * containerSize.width,
                    height: normalized.size.height * containerSize.height
                )
            }
        } else {
            let aspectRatios: [CGFloat] = project.videos.map { video in
                guard video.dimensions.height > 0 else { return 16.0 / 9.0 }
                return video.dimensions.width / video.dimensions.height
            }
            rects = LayoutEngine.calculateLayout(
                videoCount: project.videos.count,
                aspectRatios: aspectRatios,
                containerSize: containerSize,
                gap: 4
            )
        }

        lastKey = key
        lastRects = rects
        return rects
    }

    /// Clears the cached layout result.
    func invalidate() {
        lastKey = nil
        lastRects = []
    }
}

/// Hashable layout input snapshot.
private struct LayoutCacheKey: Equatable {
    /// Container width.
    let width: CGFloat

    /// Container height.
    let height: CGFloat

    /// Per-video layout inputs.
    let videos: [VideoLayoutKey]

    /// Creates a layout key from project state.
    ///
    /// - Parameters:
    ///   - project: Source project.
    ///   - containerSize: Container size.
    init(project: CoreoProject, containerSize: CGSize) {
        width = containerSize.width
        height = containerSize.height
        videos = project.videos.map { video in
            VideoLayoutKey(
                id: video.id,
                dimensions: video.dimensions,
                panelRectOverride: video.panelRectOverride
            )
        }
    }
}

/// Hashable video-level layout input snapshot.
private struct VideoLayoutKey: Equatable {
    /// Video identity.
    let id: UUID

    /// Source dimensions.
    let dimensions: CGSize

    /// Optional normalized manual panel override.
    let panelRectOverride: CGRect?
}
