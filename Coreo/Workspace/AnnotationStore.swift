// AnnotationStore.swift
// Coreo
//
// Observable annotation data and selection state for the workspace.

import Observation
import SwiftUI

/// Stores annotation data, tool selection, and annotation CRUD behavior.
@MainActor
@Observable
final class AnnotationStore {
    /// Current annotation collection.
    var annotations: [TimedAnnotation]

    /// The currently selected annotation tool.
    var selectedAnnotationTool: AnnotationTool = .pencil

    /// The currently selected annotation color hex string.
    var selectedAnnotationColorHex: String = "#FF6B36"

    /// ID of the currently selected annotation.
    var selectedAnnotationID: UUID?

    /// Creates an annotation store.
    ///
    /// - Parameter annotations: Initial annotation collection.
    init(annotations: [TimedAnnotation]) {
        self.annotations = annotations
    }

    /// Replaces the annotation collection from the project.
    ///
    /// - Parameter annotations: Updated annotation collection.
    func updateAnnotations(_ annotations: [TimedAnnotation]) {
        self.annotations = annotations
    }

    /// Clears transient selection state.
    func clearSelection() {
        selectedAnnotationID = nil
    }

    /// Adds a freehand drawing annotation at the current playhead.
    ///
    /// - Parameters:
    ///   - drawingData: PencilKit drawing data.
    ///   - currentTimeSeconds: Current playhead time.
    ///   - timelineStart: Timeline start.
    ///   - timelineEnd: Timeline end.
    func addDrawingAnnotation(
        drawingData: Data,
        currentTimeSeconds: Double,
        timelineStart: Double,
        timelineEnd: Double
    ) {
        let timeRange = TimedAnnotation.defaultTimeRange(
            at: currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: timeRange.start,
            durationSeconds: timeRange.duration,
            isPersistent: false,
            content: .drawing(DrawingAnnotation(drawingData: drawingData)),
            createdAt: Date()
        )
        annotations.append(annotation)
    }

    /// Adds a text annotation at the given normalized position.
    ///
    /// - Parameters:
    ///   - text: Text to render.
    ///   - position: Normalized annotation position.
    ///   - currentTimeSeconds: Current playhead time.
    ///   - timelineStart: Timeline start.
    ///   - timelineEnd: Timeline end.
    func addTextAnnotation(
        text: String,
        position: CGPoint,
        currentTimeSeconds: Double,
        timelineStart: Double,
        timelineEnd: Double
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let timeRange = TimedAnnotation.defaultTimeRange(
            at: currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: timeRange.start,
            durationSeconds: timeRange.duration,
            isPersistent: false,
            content: .text(TextAnnotation(
                text: text,
                position: position,
                fontSize: 16,
                colorHex: selectedAnnotationColorHex
            )),
            createdAt: Date()
        )
        annotations.append(annotation)
    }

    /// Adds an arrow annotation between two normalized points.
    ///
    /// - Parameters:
    ///   - start: Normalized start point.
    ///   - end: Normalized end point.
    ///   - currentTimeSeconds: Current playhead time.
    ///   - timelineStart: Timeline start.
    ///   - timelineEnd: Timeline end.
    func addArrowAnnotation(
        start: CGPoint,
        end: CGPoint,
        currentTimeSeconds: Double,
        timelineStart: Double,
        timelineEnd: Double
    ) {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        guard sqrt(deltaX * deltaX + deltaY * deltaY) > 0.02 else { return }
        let timeRange = TimedAnnotation.defaultTimeRange(
            at: currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: timeRange.start,
            durationSeconds: timeRange.duration,
            isPersistent: false,
            content: .arrow(ArrowAnnotation(
                start: start,
                end: end,
                colorHex: selectedAnnotationColorHex,
                lineWidth: 3
            )),
            createdAt: Date()
        )
        annotations.append(annotation)
    }

    /// Deletes the annotation with the given ID.
    ///
    /// - Parameter id: Annotation identity.
    func deleteAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id {
            selectedAnnotationID = nil
        }
    }

    /// Updates a text annotation's position.
    ///
    /// - Parameters:
    ///   - id: Annotation identity.
    ///   - position: Normalized position.
    func updateAnnotationPosition(id: UUID, position: CGPoint) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        if case var .text(text) = annotations[idx].content {
            text.position = position
            annotations[idx].content = .text(text)
        }
    }
}
