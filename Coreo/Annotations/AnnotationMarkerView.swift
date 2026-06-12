// AnnotationMarkerView.swift
// Coreo
//
// Small colored dots on the timeline showing where annotations exist.
// Each dot is positioned at the annotation's start time and colored
// based on the annotation's content type and color.

import SwiftUI

/// Displays colored marker dots on the timeline for each annotation.
///
/// Each marker is a small circle positioned proportionally along the
/// timeline width. The color reflects the annotation's content:
/// text and arrow annotations use their own color hex; drawings default
/// to white.
struct AnnotationMarkerView: View {
    /// All annotations in the project (visible or not).
    let annotations: [TimedAnnotation]

    /// The earliest point on the timeline in seconds.
    let timelineStart: Double

    /// The total duration of the timeline in seconds.
    let timelineDuration: Double

    /// The height of the marker row.
    let height: CGFloat = 44

    /// Called when the user taps an annotation marker.
    let onTapAnnotation: (TimedAnnotation) -> Void

    /// Diameter of each marker dot.
    private let markerDiameter: CGFloat = 28

    /// Effective touch target for each marker.
    private let hitTarget: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Color.clear

                ForEach(annotations) { annotation in
                    let x = xPosition(for: annotation.startTimeSeconds, in: width)
                    let color = markerColor(for: annotation)

                    Button {
                        onTapAnnotation(annotation)
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: markerDiameter, height: markerDiameter)
                            .shadow(color: color.opacity(0.5), radius: 2, x: 0, y: 0)
                            .frame(width: hitTarget, height: hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: x, y: height / 2)
                    .accessibilityLabel("Annotation marker")
                    .accessibilityValue(TimeFormatting.formatShort(annotation.startTimeSeconds - timelineStart))
                }
            }
        }
        .frame(height: height)
    }

    // MARK: - Positioning

    /// Converts an annotation's start time to an x-coordinate on the marker row.
    ///
    /// - Parameters:
    ///   - seconds: The annotation start time in seconds.
    ///   - width: The available width of the marker row.
    /// - Returns: The x-coordinate for the marker dot.
    private func xPosition(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard timelineDuration > 0 else { return 0 }
        let fraction = (seconds - timelineStart) / timelineDuration
        let clamped = min(max(fraction, 0), 1)
        return CGFloat(clamped) * width
    }

    // MARK: - Color Resolution

    /// Determines the display color for a marker based on annotation content.
    ///
    /// - Parameter annotation: The timed annotation.
    /// - Returns: The color for the marker dot. Text and arrow annotations
    ///   use their stored color hex; drawings default to white.
    private func markerColor(for annotation: TimedAnnotation) -> Color {
        switch annotation.content {
        case let .text(text):
            Color(hex: text.colorHex)
        case let .arrow(arrow):
            Color(hex: arrow.colorHex)
        case .drawing:
            .white
        }
    }
}
