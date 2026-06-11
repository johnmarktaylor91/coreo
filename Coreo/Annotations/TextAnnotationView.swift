// TextAnnotationView.swift
// Coreo
//
// Renders a single text annotation on the annotation overlay. Positions text
// at normalized coordinates converted to absolute positions within the
// container. Supports selection highlighting and drag-to-reposition.

import SwiftUI

/// Displays a text annotation label positioned over the video grid.
///
/// The annotation's `position` is in normalized (0-1) coordinates and is
/// converted to absolute coordinates using `containerSize`. When selected,
/// the view shows a border and becomes draggable.
struct TextAnnotationView: View {
    /// The text annotation data to render.
    let annotation: TextAnnotation

    /// Whether this annotation is currently selected for editing.
    let isSelected: Bool

    /// Called when the user taps on this annotation.
    let onTap: () -> Void

    /// Called during a drag with the new normalized (0-1) position.
    let onDrag: (CGPoint) -> Void

    /// The absolute size of the container (video grid area).
    let containerSize: CGSize

    /// Tracks the cumulative drag offset during an active gesture.
    @State private var dragOffset: CGSize = .zero

    /// The app's coral accent color for the selection indicator.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// The absolute position of this annotation within the container.
    private var absolutePosition: CGPoint {
        CGPoint(
            x: annotation.position.x * containerSize.width,
            y: annotation.position.y * containerSize.height
        )
    }

    var body: some View {
        Text(annotation.text)
            .font(.system(size: annotation.fontSize, weight: .semibold))
            .foregroundColor(Color(hex: annotation.colorHex))
            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isSelected ? accentCoral : Color.clear,
                        lineWidth: isSelected ? 1.5 : 0
                    )
            )
            .position(
                x: absolutePosition.x + dragOffset.width,
                y: absolutePosition.y + dragOffset.height
            )
            .onTapGesture {
                onTap()
            }
            .gesture(
                isSelected ? dragGesture : nil
            )
    }

    // MARK: - Drag Gesture

    /// The drag gesture for repositioning a selected text annotation.
    ///
    /// Updates `dragOffset` during the gesture, then converts the final
    /// position back to normalized coordinates and reports via `onDrag`.
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let newAbsoluteX = absolutePosition.x + value.translation.width
                let newAbsoluteY = absolutePosition.y + value.translation.height

                // Clamp to container bounds
                let clampedX = min(max(newAbsoluteX, 0), containerSize.width)
                let clampedY = min(max(newAbsoluteY, 0), containerSize.height)

                // Convert back to normalized
                let normalizedX = containerSize.width > 0 ? clampedX / containerSize.width : 0.5
                let normalizedY = containerSize.height > 0 ? clampedY / containerSize.height : 0.5

                let newPosition = CGPoint(x: normalizedX, y: normalizedY)
                onDrag(newPosition)
                dragOffset = .zero
            }
    }
}
