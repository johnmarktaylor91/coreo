// ArrowAnnotationView.swift
// Coreo
//
// Renders a single directional arrow annotation on the overlay. Draws a line
// from start to end (both in normalized coordinates) with a triangular
// arrowhead at the tip. Uses a custom Shape for the arrow path.

import SwiftUI

/// Displays a directional arrow annotation over the video grid.
///
/// The arrow's `start` and `end` points are in normalized (0-1) coordinates,
/// converted to absolute positions using `containerSize`. When selected,
/// grab handles are shown at both endpoints.
struct ArrowAnnotationView: View {
    /// The arrow annotation data to render.
    let annotation: ArrowAnnotation

    /// Whether this annotation is currently selected for editing.
    let isSelected: Bool

    /// The absolute size of the container (video grid area).
    let containerSize: CGSize

    /// The app's coral accent color for selection handles.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// The absolute start point within the container.
    private var absoluteStart: CGPoint {
        CGPoint(
            x: annotation.start.x * containerSize.width,
            y: annotation.start.y * containerSize.height
        )
    }

    /// The absolute end point within the container.
    private var absoluteEnd: CGPoint {
        CGPoint(
            x: annotation.end.x * containerSize.width,
            y: annotation.end.y * containerSize.height
        )
    }

    var body: some View {
        ZStack {
            // The arrow shape
            ArrowShape(
                start: absoluteStart,
                end: absoluteEnd,
                headLength: max(annotation.lineWidth * 4, 12)
            )
            .stroke(
                Color(hex: annotation.colorHex),
                style: StrokeStyle(
                    lineWidth: annotation.lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )

            // Filled arrowhead
            ArrowheadShape(
                end: absoluteEnd,
                direction: arrowDirection,
                headLength: max(annotation.lineWidth * 4, 12)
            )
            .fill(Color(hex: annotation.colorHex))

            // Selection handles at endpoints
            if isSelected {
                selectionHandle(at: absoluteStart)
                selectionHandle(at: absoluteEnd)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .allowsHitTesting(isSelected)
    }

    /// The angle of the arrow in radians, from start to end.
    private var arrowDirection: CGFloat {
        let dx = absoluteEnd.x - absoluteStart.x
        let dy = absoluteEnd.y - absoluteStart.y
        return atan2(dy, dx)
    }

    /// A small circle grab handle rendered at the given point.
    ///
    /// - Parameter point: The absolute position for the handle.
    private func selectionHandle(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .strokeBorder(accentCoral, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            .position(point)
    }
}

// MARK: - Arrow Shape

/// A Shape that draws a line from `start` to just before the arrowhead tip.
///
/// The shaft stops short of `end` by `headLength` so the arrowhead shape
/// can fill the tip cleanly without overlap.
struct ArrowShape: Shape {
    /// The starting point of the arrow shaft.
    var start: CGPoint

    /// The ending point (tip) of the arrow.
    var end: CGPoint

    /// The length of the arrowhead, used to shorten the shaft.
    var headLength: CGFloat = 12

    func path(in _: CGRect) -> Path {
        var path = Path()

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)

        guard length > headLength else {
            // Arrow too short for a head — just draw a line
            path.move(to: start)
            path.addLine(to: end)
            return path
        }

        // Shorten the shaft so it doesn't poke through the arrowhead
        let shortenFraction = (length - headLength * 0.5) / length
        let shaftEnd = CGPoint(
            x: start.x + dx * shortenFraction,
            y: start.y + dy * shortenFraction
        )

        path.move(to: start)
        path.addLine(to: shaftEnd)

        return path
    }
}

// MARK: - Arrowhead Shape

/// A filled triangular shape forming the arrowhead at the tip of an arrow.
///
/// The triangle points in `direction` with its apex at `end` and two wings
/// spread at +/-30 degrees behind the tip.
struct ArrowheadShape: Shape {
    /// The position of the arrowhead tip.
    var end: CGPoint

    /// The angle of the arrow in radians (atan2 from start to end).
    var direction: CGFloat

    /// The length of the arrowhead from tip to base.
    var headLength: CGFloat = 12

    /// The half-angle spread of the arrowhead wings in radians (~30 degrees).
    private let wingAngle: CGFloat = .pi / 6

    func path(in _: CGRect) -> Path {
        var path = Path()

        // Left wing point
        let leftX = end.x - headLength * cos(direction - wingAngle)
        let leftY = end.y - headLength * sin(direction - wingAngle)

        // Right wing point
        let rightX = end.x - headLength * cos(direction + wingAngle)
        let rightY = end.y - headLength * sin(direction + wingAngle)

        path.move(to: end)
        path.addLine(to: CGPoint(x: leftX, y: leftY))
        path.addLine(to: CGPoint(x: rightX, y: rightY))
        path.closeSubpath()

        return path
    }
}
