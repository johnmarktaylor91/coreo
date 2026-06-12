// AnnotationRasterizer.swift
// Coreo
//
// Shared rasterization for preview and export annotation rendering.

import AVFoundation
import CoreImage
import PencilKit
import UIKit

// MARK: - Coordinate Mapping

/// Converts annotation authoring coordinates into normalized and destination space.
enum AnnotationCoordinateMapper {
    /// Converts a point in the authoring canvas to normalized video-grid space.
    ///
    /// - Parameters:
    ///   - point: Point in authoring canvas coordinates.
    ///   - canvasSize: Authoring canvas size.
    /// - Returns: Point normalized into 0...1 grid coordinates.
    static func normalizedPoint(_ point: CGPoint, canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: canvasSize.width > 0 ? point.x / canvasSize.width : 0,
            y: canvasSize.height > 0 ? point.y / canvasSize.height : 0
        )
    }

    /// Converts a normalized video-grid point into destination coordinates.
    ///
    /// - Parameters:
    ///   - point: Point normalized into 0...1 grid coordinates.
    ///   - destinationRect: Destination rectangle.
    /// - Returns: Point in destination coordinates.
    static func destinationPoint(_ point: CGPoint, destinationRect: CGRect) -> CGPoint {
        CGPoint(
            x: destinationRect.minX + point.x * destinationRect.width,
            y: destinationRect.minY + point.y * destinationRect.height
        )
    }

    /// Converts a point from authoring canvas coordinates into destination coordinates.
    ///
    /// - Parameters:
    ///   - point: Point in authoring canvas coordinates.
    ///   - canvasSize: Authoring canvas size.
    ///   - destinationRect: Destination rectangle.
    /// - Returns: Point in destination coordinates.
    static func destinationPoint(
        _ point: CGPoint,
        canvasSize: CGSize,
        destinationRect: CGRect
    ) -> CGPoint {
        destinationPoint(
            normalizedPoint(point, canvasSize: canvasSize),
            destinationRect: destinationRect
        )
    }
}

// MARK: - Raster Cache

/// Thread-safe raster cache keyed by annotation identity, content signature, and destination size.
final class AnnotationRasterCache: @unchecked Sendable {
    private struct Key: Hashable {
        let id: UUID
        let signature: String
        let width: Int
        let height: Int
    }

    private var images: [Key: UIImage] = [:]
    private let lock = NSLock()

    /// Number of cached images.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    /// Returns a cached image or stores a newly rendered image.
    ///
    /// - Parameters:
    ///   - annotation: Annotation being rendered.
    ///   - destinationSize: Destination raster size.
    ///   - render: Renderer used on cache miss.
    /// - Returns: Cached or newly-rendered image.
    func image(
        for annotation: TimedAnnotation,
        destinationSize: CGSize,
        render: () -> UIImage?
    ) -> UIImage? {
        let key = Key(
            id: annotation.id,
            signature: annotation.rasterCacheSignature(),
            width: Int(destinationSize.width.rounded()),
            height: Int(destinationSize.height.rounded())
        )
        lock.lock()
        if let image = images[key] {
            lock.unlock()
            return image
        }
        lock.unlock()

        guard let image = render() else { return nil }

        lock.lock()
        images[key] = image
        lock.unlock()
        return image
    }

    /// Invalidates all cached rasters for one annotation.
    ///
    /// - Parameter id: Annotation identity to remove from the cache.
    func invalidate(annotationID id: UUID) {
        lock.lock()
        images = images.filter { $0.key.id != id }
        lock.unlock()
    }

    /// Clears all cached rasters.
    func removeAll() {
        lock.lock()
        images.removeAll()
        lock.unlock()
    }
}

// MARK: - Rasterizer

/// Renders annotations into transparent bitmap images shared by preview and export.
enum AnnotationRasterizer {
    /// Renders an annotation into a transparent image at the destination size.
    ///
    /// - Parameters:
    ///   - annotation: Annotation to render.
    ///   - destinationSize: Output image size.
    /// - Returns: A transparent image containing the annotation, or nil when rendering fails.
    static func image(for annotation: TimedAnnotation, destinationSize: CGSize) -> UIImage? {
        guard destinationSize.width > 0, destinationSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: destinationSize, format: format)

        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: destinationSize))
            switch annotation.content {
            case let .drawing(drawing):
                renderDrawing(drawing, annotation: annotation, destinationSize: destinationSize)
            case let .text(text):
                renderText(text, annotation: annotation, destinationSize: destinationSize)
            case let .arrow(arrow):
                renderArrow(arrow, annotation: annotation, destinationSize: destinationSize)
            }
        }
    }

    /// Renders a drawing annotation into the active graphics context.
    ///
    /// - Parameters:
    ///   - drawing: Drawing payload.
    ///   - annotation: Owning timed annotation.
    ///   - destinationSize: Output image size.
    private static func renderDrawing(
        _ drawing: DrawingAnnotation,
        annotation: TimedAnnotation,
        destinationSize: CGSize
    ) {
        let canvasSize = annotation.canvasSize ?? destinationSize
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              let pkDrawing = try? PKDrawing(data: drawing.drawingData)
        else {
            return
        }

        let sourceBounds = CGRect(origin: .zero, size: canvasSize)
        let image = pkDrawing.image(from: sourceBounds, scale: 1)
        image.draw(in: CGRect(origin: .zero, size: destinationSize))
    }

    /// Renders a text annotation into the active graphics context.
    ///
    /// - Parameters:
    ///   - text: Text payload.
    ///   - annotation: Owning timed annotation.
    ///   - destinationSize: Output image size.
    private static func renderText(
        _ text: TextAnnotation,
        annotation: TimedAnnotation,
        destinationSize: CGSize
    ) {
        let canvasSize = annotation.canvasSize ?? destinationSize
        let scale = canvasSize.width > 0 ? destinationSize.width / canvasSize.width : 1
        let font = UIFont.systemFont(ofSize: max(1, text.fontSize * scale), weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(coreoHex: text.colorHex),
            .paragraphStyle: paragraph,
        ]
        let maxTextSize = CGSize(width: destinationSize.width * 0.8, height: destinationSize.height)
        let textSize = (text.text as NSString).boundingRect(
            with: maxTextSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).integral.size

        let paddingX = 6 * scale
        let paddingY = 3 * scale
        let center = AnnotationCoordinateMapper.destinationPoint(
            text.position,
            destinationRect: CGRect(origin: .zero, size: destinationSize)
        )
        let pillRect = CGRect(
            x: center.x - (textSize.width + paddingX * 2) / 2,
            y: center.y - (textSize.height + paddingY * 2) / 2,
            width: textSize.width + paddingX * 2,
            height: textSize.height + paddingY * 2
        )
        UIColor.black.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: pillRect, cornerRadius: 4 * scale).fill()

        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 1 * scale), blur: 2 * scale, color: UIColor.black.withAlphaComponent(0.8).cgColor)
        let textRect = pillRect.insetBy(dx: paddingX, dy: paddingY)
        (text.text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        context.restoreGState()
    }

    /// Renders an arrow annotation into the active graphics context.
    ///
    /// - Parameters:
    ///   - arrow: Arrow payload.
    ///   - annotation: Owning timed annotation.
    ///   - destinationSize: Output image size.
    private static func renderArrow(
        _ arrow: ArrowAnnotation,
        annotation: TimedAnnotation,
        destinationSize: CGSize
    ) {
        let canvasSize = annotation.canvasSize ?? destinationSize
        let scale = canvasSize.width > 0 ? destinationSize.width / canvasSize.width : 1
        let start = AnnotationCoordinateMapper.destinationPoint(
            arrow.start,
            destinationRect: CGRect(origin: .zero, size: destinationSize)
        )
        let end = AnnotationCoordinateMapper.destinationPoint(
            arrow.end,
            destinationRect: CGRect(origin: .zero, size: destinationSize)
        )
        let lineWidth = max(1, arrow.lineWidth * scale)
        let headLength = max(lineWidth * 4, 12 * scale)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        let shaftEnd: CGPoint
        if length > headLength {
            let shortenFraction = (length - headLength * 0.5) / length
            shaftEnd = CGPoint(x: start.x + dx * shortenFraction, y: start.y + dy * shortenFraction)
        } else {
            shaftEnd = end
        }

        let color = UIColor(coreoHex: arrow.colorHex)
        color.setStroke()
        color.setFill()

        let shaft = UIBezierPath()
        shaft.move(to: start)
        shaft.addLine(to: shaftEnd)
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        shaft.lineJoinStyle = .round
        shaft.stroke()

        let direction = atan2(dy, dx)
        let wingAngle = CGFloat.pi / 6
        let left = CGPoint(
            x: end.x - headLength * cos(direction - wingAngle),
            y: end.y - headLength * sin(direction - wingAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(direction + wingAngle),
            y: end.y - headLength * sin(direction + wingAngle)
        )
        let head = UIBezierPath()
        head.move(to: end)
        head.addLine(to: left)
        head.addLine(to: right)
        head.close()
        head.fill()
    }
}

// MARK: - Export Renderer

/// PanelCompositor annotation renderer backed by the shared bitmap rasterizer.
struct AnnotationExportFrameRenderer: AnnotationFrameRendering {
    private let annotations: [TimedAnnotation]
    private let timeMapper: TimeMapper
    private let timelineStart: Double
    private let cache: AnnotationRasterCache

    /// Creates an export annotation renderer.
    ///
    /// - Parameters:
    ///   - annotations: Project annotations to render.
    ///   - timeMapper: Mapper from export output time back to timeline time.
    ///   - timelineStart: Project timeline start.
    ///   - cache: Shared raster cache.
    init(
        annotations: [TimedAnnotation],
        timeMapper: TimeMapper,
        timelineStart: Double,
        cache: AnnotationRasterCache = AnnotationRasterCache()
    ) {
        self.annotations = annotations
        self.timeMapper = timeMapper
        self.timelineStart = timelineStart
        self.cache = cache
    }

    /// Renders annotations over the current frame result.
    ///
    /// - Parameters:
    ///   - image: Current composited frame.
    ///   - time: Composition time for the frame.
    ///   - renderSize: Output render size.
    /// - Returns: Frame image after annotation rendering.
    func renderAnnotations(
        over image: CIImage,
        at time: CMTime,
        renderSize: CGSize
    ) -> CIImage {
        let exportSeconds = CMTimeGetSeconds(time)
        guard exportSeconds.isFinite else { return image }
        let timelineSeconds = timeMapper.timelineTime(
            forExport: exportSeconds,
            timelineStart: timelineStart
        )
        var result = image
        for annotation in annotations {
            let opacity = annotation.opacity(at: timelineSeconds)
            guard opacity > 0,
                  let uiImage = cache.image(
                      for: annotation,
                      destinationSize: renderSize,
                      render: { AnnotationRasterizer.image(for: annotation, destinationSize: renderSize) }
                  ),
                  let cgImage = uiImage.cgImage
            else {
                continue
            }
            let overlay = CIImage(cgImage: cgImage)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                ])
            result = overlay.composited(over: result)
        }
        return result
    }
}

// MARK: - UIColor Hex

private extension UIColor {
    /// Creates a UIColor from a hex string.
    ///
    /// - Parameter coreoHex: Hex string in RRGGBB or RRGGBBAA form.
    convenience init(coreoHex: String) {
        let cleaned = coreoHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgba: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgba)
        switch cleaned.count {
        case 8:
            self.init(
                red: CGFloat((rgba >> 24) & 0xFF) / 255,
                green: CGFloat((rgba >> 16) & 0xFF) / 255,
                blue: CGFloat((rgba >> 8) & 0xFF) / 255,
                alpha: CGFloat(rgba & 0xFF) / 255
            )
        default:
            self.init(
                red: CGFloat((rgba >> 16) & 0xFF) / 255,
                green: CGFloat((rgba >> 8) & 0xFF) / 255,
                blue: CGFloat(rgba & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
