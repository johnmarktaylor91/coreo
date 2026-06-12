// AnnotationModel.swift
// Coreo
//
// Data models for time-stamped annotations: freehand drawings (PencilKit),
// text labels, and directional arrows. Each annotation has a visible time
// range with fade-in/fade-out transitions.

import SwiftUI

// MARK: - TimedAnnotation

/// A single annotation pinned to a time range on the project timeline.
struct TimedAnnotation: Codable, Identifiable {
    /// Unique identifier.
    let id: UUID

    /// Timeline time (seconds) when this annotation becomes visible.
    var startTimeSeconds: Double

    /// How long (seconds) the annotation remains visible.
    var durationSeconds: Double

    /// When true, the annotation is visible for the entire timeline regardless of start/duration.
    var isPersistent: Bool

    /// The visual content of the annotation.
    var content: AnnotationContent

    /// Size of the video-grid canvas where this annotation was authored.
    var canvasSize: CGSize?

    /// Timestamp when this annotation was created.
    var createdAt: Date

    /// Creates a timed annotation.
    ///
    /// - Parameters:
    ///   - id: Unique annotation identity.
    ///   - startTimeSeconds: Timeline time when the annotation becomes visible.
    ///   - durationSeconds: Visible duration in timeline seconds.
    ///   - isPersistent: Whether the annotation remains visible for the full timeline.
    ///   - content: Visual annotation payload.
    ///   - canvasSize: Size of the authoring video-grid canvas.
    ///   - createdAt: Creation timestamp.
    init(
        id: UUID,
        startTimeSeconds: Double,
        durationSeconds: Double,
        isPersistent: Bool,
        content: AnnotationContent,
        canvasSize: CGSize? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.startTimeSeconds = startTimeSeconds
        self.durationSeconds = durationSeconds
        self.isPersistent = isPersistent
        self.content = content
        self.canvasSize = canvasSize
        self.createdAt = createdAt
    }

    // MARK: - Computed Properties

    /// Timeline time (seconds) when this annotation stops being visible.
    var endTimeSeconds: Double {
        startTimeSeconds + durationSeconds
    }

    /// Returns the display opacity (0.0-1.0) for this annotation at a given timeline time.
    ///
    /// Persistent annotations always return 1.0. Timed annotations fade in over 0.2s
    /// at the start of their range and fade out over 0.2s at the end.
    ///
    /// - Parameter currentTime: The current playhead position in seconds.
    /// - Returns: Opacity from 0.0 (invisible) to 1.0 (fully visible).
    func opacity(at currentTime: Double) -> Double {
        if isPersistent {
            return 1.0
        }

        guard currentTime >= startTimeSeconds, currentTime <= endTimeSeconds else {
            return 0.0
        }

        let fadeInDuration = 0.2
        let fadeOutDuration = 0.2

        // How far past the start we are
        let elapsed = currentTime - startTimeSeconds
        // How far before the end we are
        let remaining = endTimeSeconds - currentTime

        var result = 1.0

        // Fade in
        if elapsed < fadeInDuration {
            result = min(result, elapsed / fadeInDuration)
        }

        // Fade out
        if remaining < fadeOutDuration {
            result = min(result, remaining / fadeOutDuration)
        }

        return max(0.0, min(1.0, result))
    }

    /// Whether this annotation should be displayed at the given time.
    ///
    /// - Parameter currentTime: The current playhead position in seconds.
    /// - Returns: True if the annotation is visible (persistent or within its time range).
    func isVisible(at currentTime: Double) -> Bool {
        if isPersistent { return true }
        return currentTime >= startTimeSeconds && currentTime <= endTimeSeconds
    }

    /// Stable content signature used to invalidate raster caches.
    ///
    /// - Returns: A deterministic string for annotation content and geometry.
    func rasterCacheSignature() -> String {
        let canvas = canvasSize.map { "\($0.width)x\($0.height)" } ?? "nil"
        return "\(id.uuidString)|\(canvas)|\(content.rasterCacheSignature())"
    }

    /// Calculates a default 3-second annotation window centered on the playhead,
    /// clamped to the timeline bounds.
    ///
    /// - Parameters:
    ///   - playheadSeconds: Current playhead position.
    ///   - timelineStart: Earliest point on the timeline.
    ///   - timelineEnd: Latest point on the timeline.
    /// - Returns: A tuple of (start, duration) in seconds.
    static func defaultTimeRange(
        at playheadSeconds: Double,
        timelineStart: Double,
        timelineEnd: Double
    ) -> (start: Double, duration: Double) {
        let defaultDuration = 3.0
        let halfDuration = defaultDuration / 2.0

        var start = playheadSeconds - halfDuration
        var end = playheadSeconds + halfDuration

        // Clamp to timeline bounds
        if start < timelineStart {
            start = timelineStart
            end = min(start + defaultDuration, timelineEnd)
        }

        if end > timelineEnd {
            end = timelineEnd
            start = max(end - defaultDuration, timelineStart)
        }

        let duration = end - start
        return (start: start, duration: max(0, duration))
    }
}

// MARK: - AnnotationContent

/// The visual payload of an annotation: a freehand drawing, a text label, or an arrow.
enum AnnotationContent: Codable {
    case drawing(DrawingAnnotation)
    case text(TextAnnotation)
    case arrow(ArrowAnnotation)

    // MARK: - Custom Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum ContentType: String, Codable {
        case drawing
        case text
        case arrow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ContentType.self, forKey: .type)

        switch type {
        case .drawing:
            let payload = try container.decode(DrawingAnnotation.self, forKey: .payload)
            self = .drawing(payload)
        case .text:
            let payload = try container.decode(TextAnnotation.self, forKey: .payload)
            self = .text(payload)
        case .arrow:
            let payload = try container.decode(ArrowAnnotation.self, forKey: .payload)
            self = .arrow(payload)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .drawing(drawing):
            try container.encode(ContentType.drawing, forKey: .type)
            try container.encode(drawing, forKey: .payload)
        case let .text(text):
            try container.encode(ContentType.text, forKey: .type)
            try container.encode(text, forKey: .payload)
        case let .arrow(arrow):
            try container.encode(ContentType.arrow, forKey: .type)
            try container.encode(arrow, forKey: .payload)
        }
    }

    /// Stable content signature used to invalidate raster caches.
    ///
    /// - Returns: A deterministic string for the visual content.
    func rasterCacheSignature() -> String {
        switch self {
        case let .drawing(drawing):
            drawing.rasterCacheSignature()
        case let .text(text):
            text.rasterCacheSignature()
        case let .arrow(arrow):
            arrow.rasterCacheSignature()
        }
    }
}

// MARK: - Drawing Annotation

/// A freehand drawing captured via PencilKit, stored as serialized data.
struct DrawingAnnotation: Codable {
    /// PKDrawing serialized via `dataRepresentation()`.
    var drawingData: Data

    /// Stable content signature used to invalidate raster caches.
    ///
    /// - Returns: A deterministic string for the drawing payload.
    func rasterCacheSignature() -> String {
        "drawing:\(drawingData.count):\(drawingData.base64EncodedString())"
    }
}

// MARK: - Text Annotation

/// A positioned text label overlaid on the video grid.
struct TextAnnotation: Codable {
    /// The displayed text content.
    var text: String

    /// Normalized position (0-1) within the video grid area.
    var position: CGPoint

    /// Font size in points.
    var fontSize: CGFloat

    /// Color as a hex string (e.g., "#FFFFFF").
    var colorHex: String

    /// Stable content signature used to invalidate raster caches.
    ///
    /// - Returns: A deterministic string for the text payload.
    func rasterCacheSignature() -> String {
        "text:\(text)|\(position.x),\(position.y)|\(fontSize)|\(colorHex)"
    }
}

// MARK: - Arrow Annotation

/// A directional arrow overlaid on the video grid.
struct ArrowAnnotation: Codable {
    /// Normalized start point (0-1) within the video grid area.
    var start: CGPoint

    /// Normalized end point (0-1) within the video grid area.
    var end: CGPoint

    /// Color as a hex string (e.g., "#FF3B30").
    var colorHex: String

    /// Stroke width in points.
    var lineWidth: CGFloat

    /// Stable content signature used to invalidate raster caches.
    ///
    /// - Returns: A deterministic string for the arrow payload.
    func rasterCacheSignature() -> String {
        "arrow:\(start.x),\(start.y)|\(end.x),\(end.y)|\(lineWidth)|\(colorHex)"
    }
}

// MARK: - Color Palette

extension TimedAnnotation {
    /// The standard annotation color palette.
    static let palette: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"),
        ("Red", "#FF3B30"),
        ("Yellow", "#FFD60A"),
        ("Cyan", "#64D2FF"),
        ("Green", "#30D158"),
        ("Orange", "#FF9F0A")
    ]
}

// MARK: - Color Hex Extension

extension Color {
    /// Creates a Color from a hex string ("#RRGGBB" or "#RRGGBBAA").
    ///
    /// - Parameter hex: A hex color string with a leading "#".
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexString = cleaned.hasPrefix("#") ? String(cleaned.dropFirst()) : cleaned

        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch hexString.count {
        case 6:
            red = Double((rgbValue >> 16) & 0xFF) / 255.0
            green = Double((rgbValue >> 8) & 0xFF) / 255.0
            blue = Double(rgbValue & 0xFF) / 255.0
            alpha = 1.0
        case 8:
            red = Double((rgbValue >> 24) & 0xFF) / 255.0
            green = Double((rgbValue >> 16) & 0xFF) / 255.0
            blue = Double((rgbValue >> 8) & 0xFF) / 255.0
            alpha = Double(rgbValue & 0xFF) / 255.0
        default:
            red = 0
            green = 0
            blue = 0
            alpha = 1.0
        }

        self.init(
            .sRGB,
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }

    /// Returns the hex string representation ("#RRGGBB") of this color.
    ///
    /// Falls back to "#000000" if the color cannot be resolved to sRGB components.
    var hexString: String {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#000000"
        }

        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
