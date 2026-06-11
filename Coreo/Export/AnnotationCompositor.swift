// AnnotationCompositor.swift
// Coreo
//
// Builds the CALayer tree for compositing annotations onto the exported video.
// Each annotation becomes a sublayer with a keyframe opacity animation timed
// to the composition's timeline using AVCoreAnimationBeginTimeAtZero. Drawing
// annotations are rasterized from PencilKit, text uses CATextLayer, and arrows
// use CAShapeLayer with arrowhead paths.

import AVFoundation
import PencilKit
import QuartzCore
import UIKit

// MARK: - UIColor Hex Helper (for export context where SwiftUI.Color is unavailable)

private extension UIColor {
    convenience init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

/// Builds the CALayer tree for annotation overlay during video export.
///
/// The compositor creates a parent layer containing a video layer (for the
/// composited video frames) and individual annotation sublayers, each with
/// time-based opacity animations. This layer hierarchy is consumed by
/// `AVVideoCompositionCoreAnimationTool`.
enum AnnotationCompositor {

    /// Duration of fade-in and fade-out transitions in seconds.
    private static let fadeDuration: Double = 0.2

    // MARK: - Public

    /// Builds the complete layer tree for compositing annotations onto the exported video.
    ///
    /// - Parameters:
    ///   - annotations: All annotations in the project.
    ///   - renderSize: Export resolution (e.g., 1920x1080).
    ///   - timelineStart: Start of the timeline in seconds.
    ///   - timelineDuration: Total duration of the timeline in seconds.
    /// - Returns: Tuple of (parentLayer, videoLayer) for use with
    ///   `AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer:in:)`.
    static func buildLayers(
        annotations: [TimedAnnotation],
        renderSize: CGSize,
        timelineStart: Double,
        timelineDuration: Double
    ) -> (parentLayer: CALayer, videoLayer: CALayer) {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        for annotation in annotations {
            let annotationLayer = buildAnnotationLayer(
                annotation,
                renderSize: renderSize,
                timelineStart: timelineStart,
                timelineDuration: timelineDuration
            )
            parentLayer.addSublayer(annotationLayer)
        }

        return (parentLayer: parentLayer, videoLayer: videoLayer)
    }

    /// Builds a single annotation's CALayer with opacity animation.
    ///
    /// The layer's content depends on the annotation type:
    /// - `.drawing`: PencilKit drawing rasterized to a CGImage
    /// - `.text`: CATextLayer with font, color, and position
    /// - `.arrow`: CAShapeLayer with arrowhead path
    ///
    /// An opacity keyframe animation fades the layer in/out at the
    /// annotation's start and end times.
    ///
    /// - Parameters:
    ///   - annotation: The timed annotation to render.
    ///   - renderSize: Export resolution.
    ///   - timelineStart: Start of the timeline in seconds.
    ///   - timelineDuration: Total duration of the timeline in seconds.
    /// - Returns: A configured CALayer ready to be added to the parent layer.
    static func buildAnnotationLayer(
        _ annotation: TimedAnnotation,
        renderSize: CGSize,
        timelineStart: Double,
        timelineDuration: Double
    ) -> CALayer {
        let contentLayer: CALayer

        switch annotation.content {
        case .drawing(let drawing):
            contentLayer = buildDrawingLayer(drawing, renderSize: renderSize)
        case .text(let text):
            contentLayer = buildTextLayer(text, renderSize: renderSize)
        case .arrow(let arrow):
            contentLayer = buildArrowLayer(arrow, renderSize: renderSize)
        }

        // Initial state: hidden
        contentLayer.opacity = 0

        // Apply opacity animation
        let opacityAnimation = buildOpacityAnimation(
            annotation: annotation,
            timelineStart: timelineStart,
            timelineDuration: timelineDuration
        )
        contentLayer.add(opacityAnimation, forKey: "annotationOpacity")

        return contentLayer
    }

    // MARK: - Content Layer Builders

    /// Rasterizes a PencilKit drawing into a CALayer.
    ///
    /// - Parameters:
    ///   - drawing: The drawing annotation data.
    ///   - renderSize: Export resolution.
    /// - Returns: A CALayer with the drawing as its contents, or empty on failure.
    private static func buildDrawingLayer(
        _ drawing: DrawingAnnotation,
        renderSize: CGSize
    ) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)

        guard let pkDrawing = try? PKDrawing(data: drawing.drawingData) else {
            return layer
        }

        // Rasterize the drawing at export resolution.
        // PencilKit drawings use point coordinates; we scale to fill the render size.
        let drawingBounds = CGRect(origin: .zero, size: renderSize)
        let scale: CGFloat = 2.0  // High quality for export
        let image = pkDrawing.image(from: drawingBounds, scale: scale)
        layer.contents = image.cgImage
        layer.contentsGravity = .resizeAspectFill

        return layer
    }

    /// Creates a CATextLayer for a text annotation.
    ///
    /// The text position is stored in normalized (0-1) coordinates and scaled
    /// to the export resolution. Font size is similarly scaled.
    ///
    /// - Parameters:
    ///   - text: The text annotation data.
    ///   - renderSize: Export resolution.
    /// - Returns: A configured CATextLayer.
    private static func buildTextLayer(
        _ text: TextAnnotation,
        renderSize: CGSize
    ) -> CALayer {
        let textLayer = CATextLayer()

        // Scale factor: annotations are authored at ~375pt screen width,
        // but exported at 1920px (or custom resolution).
        let scaleFactor = renderSize.width / 375.0
        let scaledFontSize = text.fontSize * scaleFactor

        textLayer.string = text.text
        textLayer.font = CTFontCreateWithName("SFProText-Medium" as CFString, scaledFontSize, nil)
        textLayer.fontSize = scaledFontSize
        textLayer.foregroundColor = UIColor(hexString: text.colorHex).cgColor
        textLayer.isWrapped = true
        textLayer.alignmentMode = .left
        textLayer.contentsScale = 2.0
        textLayer.truncationMode = .end

        // Calculate frame from normalized position.
        // Position represents the top-left corner in normalized coords.
        let maxWidth = renderSize.width * 0.5  // Text blocks max half the width
        let x = text.position.x * renderSize.width
        let y = text.position.y * renderSize.height

        // Estimate text height (rough: 1.3x font size per line)
        let estimatedLineHeight = scaledFontSize * 1.3
        let lines = max(1, CGFloat(text.text.count) / 30.0)  // rough estimate
        let estimatedHeight = estimatedLineHeight * ceil(lines)

        textLayer.frame = CGRect(
            x: x,
            y: y,
            width: min(maxWidth, renderSize.width - x),
            height: min(estimatedHeight, renderSize.height - y)
        )

        return textLayer
    }

    /// Creates a CAShapeLayer for an arrow annotation.
    ///
    /// Arrow positions are normalized (0-1) and scaled to the export resolution.
    /// The arrowhead is a triangular cap at the endpoint.
    ///
    /// - Parameters:
    ///   - arrow: The arrow annotation data.
    ///   - renderSize: Export resolution.
    /// - Returns: A configured CAShapeLayer with arrow path.
    private static func buildArrowLayer(
        _ arrow: ArrowAnnotation,
        renderSize: CGSize
    ) -> CALayer {
        let containerLayer = CALayer()
        containerLayer.frame = CGRect(origin: .zero, size: renderSize)

        let scaleFactor = renderSize.width / 375.0
        let startPoint = CGPoint(
            x: arrow.start.x * renderSize.width,
            y: arrow.start.y * renderSize.height
        )
        let endPoint = CGPoint(
            x: arrow.end.x * renderSize.width,
            y: arrow.end.y * renderSize.height
        )

        // Shaft
        let shaftLayer = CAShapeLayer()
        shaftLayer.frame = containerLayer.bounds
        let shaftPath = CGMutablePath()
        shaftPath.move(to: startPoint)
        shaftPath.addLine(to: endPoint)
        shaftLayer.path = shaftPath
        shaftLayer.strokeColor = UIColor(hexString: arrow.colorHex).cgColor
        shaftLayer.lineWidth = arrow.lineWidth * scaleFactor
        shaftLayer.fillColor = nil
        shaftLayer.lineCap = .round
        containerLayer.addSublayer(shaftLayer)

        // Arrowhead
        let headLayer = CAShapeLayer()
        headLayer.frame = containerLayer.bounds
        let headPath = arrowheadPath(
            from: startPoint,
            to: endPoint,
            headLength: 16.0 * scaleFactor,
            headWidth: 10.0 * scaleFactor
        )
        headLayer.path = headPath
        headLayer.fillColor = UIColor(hexString: arrow.colorHex).cgColor
        headLayer.strokeColor = nil
        containerLayer.addSublayer(headLayer)

        return containerLayer
    }

    /// Generates a triangular arrowhead path at the end of a line.
    ///
    /// - Parameters:
    ///   - from: Line start point.
    ///   - to: Line end point (where the arrowhead is placed).
    ///   - headLength: Length of the arrowhead triangle.
    ///   - headWidth: Width of the arrowhead triangle base.
    /// - Returns: A CGPath for the arrowhead triangle.
    private static func arrowheadPath(
        from: CGPoint,
        to: CGPoint,
        headLength: CGFloat,
        headWidth: CGFloat
    ) -> CGPath {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return CGMutablePath() }

        // Unit vectors along and perpendicular to the arrow direction.
        let ux = dx / length
        let uy = dy / length
        let px = -uy  // perpendicular
        let py = ux

        // Triangle vertices: tip at `to`, base set back by headLength.
        let tip = to
        let baseLeft = CGPoint(
            x: to.x - ux * headLength + px * headWidth / 2,
            y: to.y - uy * headLength + py * headWidth / 2
        )
        let baseRight = CGPoint(
            x: to.x - ux * headLength - px * headWidth / 2,
            y: to.y - uy * headLength - py * headWidth / 2
        )

        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: baseLeft)
        path.addLine(to: baseRight)
        path.closeSubpath()
        return path
    }

    // MARK: - Opacity Animation

    /// Builds the opacity keyframe animation for an annotation layer.
    ///
    /// The animation uses `AVCoreAnimationBeginTimeAtZero` so that keyTimes
    /// are relative to the composition start (not wall clock time).
    ///
    /// Timing (all times normalized 0-1 relative to total timeline duration):
    /// - Before annotation start: opacity = 0
    /// - Fade in: 0 -> 1 over 0.2 seconds
    /// - Visible: opacity = 1
    /// - Fade out: 1 -> 0 over 0.2 seconds
    /// - After annotation end: opacity = 0
    ///
    /// Persistent annotations hold opacity = 1 for the entire timeline.
    ///
    /// - Parameters:
    ///   - annotation: The timed annotation.
    ///   - timelineStart: Start of the timeline in seconds.
    ///   - timelineDuration: Total duration in seconds.
    /// - Returns: A configured CAKeyframeAnimation.
    private static func buildOpacityAnimation(
        annotation: TimedAnnotation,
        timelineStart: Double,
        timelineDuration: Double
    ) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = CFTimeInterval(timelineDuration)
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards

        guard timelineDuration > 0 else {
            anim.keyTimes = [0, 1]
            anim.values = [Float(0), Float(0)]
            return anim
        }

        if annotation.isPersistent {
            // Visible for entire timeline
            anim.keyTimes = [0 as NSNumber, 1 as NSNumber]
            anim.values = [Float(1.0), Float(1.0)]
            return anim
        }

        // Convert absolute times to normalized (0-1) keyTimes
        let relativeStart = annotation.startTimeSeconds - timelineStart
        let relativeEnd = annotation.endTimeSeconds - timelineStart

        let fadeInStart = relativeStart / timelineDuration
        let fadeInEnd = min((relativeStart + fadeDuration) / timelineDuration, 1.0)
        let fadeOutStart = max((relativeEnd - fadeDuration) / timelineDuration, 0.0)
        let fadeOutEnd = min(relativeEnd / timelineDuration, 1.0)

        var keyTimes: [NSNumber] = []
        var values: [Float] = []

        // If the annotation doesn't start at the beginning, add the initial invisible segment.
        if fadeInStart > 0.001 {
            keyTimes.append(0 as NSNumber)
            values.append(0)
            // Just before fade in
            keyTimes.append(NSNumber(value: max(fadeInStart - 0.001, 0)))
            values.append(0)
        } else {
            keyTimes.append(0 as NSNumber)
            values.append(0)
        }

        // Fade in complete
        keyTimes.append(NSNumber(value: fadeInEnd))
        values.append(1.0)

        // If there's a gap between fade-in end and fade-out start, hold at 1.0
        if fadeOutStart > fadeInEnd + 0.001 {
            keyTimes.append(NSNumber(value: fadeOutStart))
            values.append(1.0)
        }

        // Fade out complete
        if fadeOutEnd < 0.999 {
            keyTimes.append(NSNumber(value: fadeOutEnd))
            values.append(0)

            // Stay invisible until the end
            keyTimes.append(1 as NSNumber)
            values.append(0)
        } else {
            keyTimes.append(1 as NSNumber)
            values.append(0)
        }

        anim.keyTimes = keyTimes
        anim.values = values

        return anim
    }
}
