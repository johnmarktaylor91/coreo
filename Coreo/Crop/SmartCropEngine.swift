// SmartCropEngine.swift
// Coreo
//
// Computes optimal crop regions for video panels based on person detection
// results. The goal is to maximize useful content in each panel by cropping
// to the activity region (where dancers are) rather than showing the full
// wide-angle frame with wasted space on the sides.

import CoreGraphics
import Foundation

/// Computes smart crop rectangles from person detection bounding boxes.
///
/// The crop algorithm:
/// 1. Union all detected person rects into a single activity region.
/// 2. Flip from Vision coordinates (origin bottom-left) to standard
///    coordinates (origin top-left).
/// 3. Pad by 15% on all sides for breathing room.
/// 4. Clamp to the [0, 1] normalized range.
///
/// Returns `nil` when no persons were detected, signaling the caller
/// to use the full frame (no crop).
enum SmartCropEngine {

    /// Default padding fraction added around the activity region.
    /// 15% on each side provides comfortable framing without losing
    /// too much of the original field of view.
    static let defaultPadding: CGFloat = 0.15

    // MARK: - Single Video

    /// Compute the smart crop rect for a video based on person detection results.
    ///
    /// - Parameters:
    ///   - detectedRects: Array of person bounding boxes in Vision coordinates
    ///     (normalized 0-1, origin at bottom-left).
    ///   - videoDimensions: Original video dimensions in pixels. Currently unused
    ///     since all rects are normalized, but reserved for future aspect-ratio-aware
    ///     cropping.
    ///   - padding: Padding fraction to add around the activity region on each side.
    ///     Default is 0.15 (15%).
    /// - Returns: Normalized crop rect in standard coordinates (origin at top-left),
    ///   or `nil` if no persons were detected (meaning: use full frame).
    static func computeCropRect(
        detectedRects: [CGRect],
        videoDimensions: CGSize,
        padding: CGFloat = 0.15
    ) -> CGRect? {
        guard !detectedRects.isEmpty else {
            return nil
        }

        // Step 1: Compute the union of all detected rects (in Vision coordinates).
        let unionRect = computeUnion(of: detectedRects)

        // Step 2: Convert from Vision coordinates (origin bottom-left) to
        // standard coordinates (origin top-left). Only the Y axis flips.
        let flippedRect = flipToStandardCoordinates(unionRect)

        // Step 3: Add padding on all sides.
        let paddedRect = addPadding(to: flippedRect, padding: padding)

        // Step 4: Clamp to the valid [0, 1] range.
        let clampedRect = clampToUnitRect(paddedRect)

        return clampedRect
    }

    // MARK: - Batch Processing

    /// Compute crop rects for multiple videos concurrently.
    ///
    /// Runs person detection on each video in parallel using a TaskGroup,
    /// then computes crop rects from the detection results.
    ///
    /// - Parameter videos: Array of (url, dimensions) tuples for each video.
    /// - Returns: Array of optional crop rects, one per video. `nil` entries
    ///   mean no persons were detected and the full frame should be used.
    static func computeCropRects(
        for videos: [(url: URL, dimensions: CGSize)]
    ) async -> [CGRect?] {
        // Use a dictionary to maintain index association across concurrent tasks.
        let indexedResults: [(Int, CGRect?)] = await withTaskGroup(
            of: (Int, CGRect?).self
        ) { group in
            for (index, video) in videos.enumerated() {
                let capturedIndex = index
                let capturedURL = video.url
                let capturedDimensions = video.dimensions

                group.addTask {
                    do {
                        let rects = try await PersonDetector.detectPersons(in: capturedURL)
                        let cropRect = computeCropRect(
                            detectedRects: rects,
                            videoDimensions: capturedDimensions
                        )
                        return (capturedIndex, cropRect)
                    } catch {
                        // Detection failed for this video — fall back to full frame.
                        return (capturedIndex, nil)
                    }
                }
            }

            var collected: [(Int, CGRect?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Reassemble into the original index order.
        var orderedResults = [CGRect?](repeating: nil, count: videos.count)
        for (index, rect) in indexedResults {
            orderedResults[index] = rect
        }
        return orderedResults
    }

    // MARK: - Private Geometry Helpers

    /// Compute the bounding box that contains all the given rects.
    private static func computeUnion(of rects: [CGRect]) -> CGRect {
        guard let first = rects.first else {
            return .zero
        }

        var result = first
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    /// Flip a rect from Vision coordinates (origin bottom-left, Y up) to
    /// standard coordinates (origin top-left, Y down) within a 0-1 space.
    ///
    /// Vision's (x, y) is the bottom-left corner of the box.
    /// Standard's (x, y) is the top-left corner of the box.
    /// So: newY = 1.0 - (visionY + visionHeight).
    private static func flipToStandardCoordinates(_ rect: CGRect) -> CGRect {
        let flippedY = 1.0 - (rect.origin.y + rect.size.height)
        return CGRect(
            x: rect.origin.x,
            y: flippedY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    /// Add padding around a rect, expanding it on all four sides.
    private static func addPadding(to rect: CGRect, padding: CGFloat) -> CGRect {
        return CGRect(
            x: rect.origin.x - padding,
            y: rect.origin.y - padding,
            width: rect.size.width + 2 * padding,
            height: rect.size.height + 2 * padding
        )
    }

    /// Clamp a rect so that all edges fall within the [0, 1] range.
    private static func clampToUnitRect(_ rect: CGRect) -> CGRect {
        let x = max(0, rect.origin.x)
        let y = max(0, rect.origin.y)
        let maxX = min(1, rect.origin.x + rect.size.width)
        let maxY = min(1, rect.origin.y + rect.size.height)

        return CGRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }
}
