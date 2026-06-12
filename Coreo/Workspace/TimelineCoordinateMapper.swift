// TimelineCoordinateMapper.swift
// Coreo
//
// Shared timeline coordinate transform for rendering and gestures.

import CoreGraphics
import Foundation

/// Converts between unified timeline seconds and horizontal timeline coordinates.
struct TimelineCoordinateMapper: Equatable {
    /// Timeline start in seconds.
    let startSeconds: Double

    /// Timeline end in seconds.
    let endSeconds: Double

    /// Left inset before drawable content.
    let leadingInset: CGFloat

    /// Right inset after drawable content.
    let trailingInset: CGFloat

    /// Creates a mapper.
    ///
    /// - Parameters:
    ///   - startSeconds: Timeline start.
    ///   - endSeconds: Timeline end.
    ///   - leadingInset: Left content inset.
    ///   - trailingInset: Right content inset.
    init(
        startSeconds: Double,
        endSeconds: Double,
        leadingInset: CGFloat = 8,
        trailingInset: CGFloat = 8
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
    }

    /// Duration represented by the mapper.
    var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }

    /// Drawable width after insets.
    ///
    /// - Parameter totalWidth: Full timeline width.
    /// - Returns: Width available for mapped content.
    func contentWidth(totalWidth: CGFloat) -> CGFloat {
        max(0, totalWidth - leadingInset - trailingInset)
    }

    /// Maps a timeline time to an x coordinate in full-width coordinates.
    ///
    /// - Parameters:
    ///   - seconds: Timeline seconds.
    ///   - totalWidth: Full timeline width.
    /// - Returns: X coordinate including the leading inset.
    func x(for seconds: Double, totalWidth: CGFloat) -> CGFloat {
        guard durationSeconds > 0 else { return leadingInset }
        let fraction = min(max((seconds - startSeconds) / durationSeconds, 0), 1)
        return leadingInset + CGFloat(fraction) * contentWidth(totalWidth: totalWidth)
    }

    /// Maps an x coordinate to timeline seconds.
    ///
    /// - Parameters:
    ///   - xPosition: X coordinate in full-width coordinates.
    ///   - totalWidth: Full timeline width.
    /// - Returns: Timeline seconds clamped to mapper bounds.
    func seconds(forX xPosition: CGFloat, totalWidth: CGFloat) -> Double {
        let width = contentWidth(totalWidth: totalWidth)
        guard width > 0, durationSeconds > 0 else { return startSeconds }
        let fraction = min(max((xPosition - leadingInset) / width, 0), 1)
        return startSeconds + Double(fraction) * durationSeconds
    }
}
