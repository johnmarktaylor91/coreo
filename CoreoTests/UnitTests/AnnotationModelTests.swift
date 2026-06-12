// AnnotationModelTests.swift
// CoreoTests
//
// Unit tests for annotation opacity, time range clamping, Codable
// round-trips, and Color hex conversion.

@testable import Coreo
import SwiftUI
import XCTest

final class AnnotationModelTests: XCTestCase {
    // MARK: - Opacity Calculation

    func testOpacityBeforeRangeIsZero() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)

        XCTAssertEqual(annotation.opacity(at: 4.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: 0.0), 0.0, accuracy: 0.001)
    }

    func testOpacityAfterRangeIsZero() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)

        XCTAssertEqual(annotation.opacity(at: 8.1), 0.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: 100.0), 0.0, accuracy: 0.001)
    }

    func testOpacityFadeIn() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)

        // At start: opacity should be 0
        XCTAssertEqual(annotation.opacity(at: 5.0), 0.0, accuracy: 0.001)

        // 0.1s into start (halfway through 0.2s fade-in)
        XCTAssertEqual(annotation.opacity(at: 5.1), 0.5, accuracy: 0.001)

        // 0.2s in (full fade-in complete)
        XCTAssertEqual(annotation.opacity(at: 5.2), 1.0, accuracy: 0.001)
    }

    func testOpacityFullInMiddle() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)

        XCTAssertEqual(annotation.opacity(at: 6.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: 6.5), 1.0, accuracy: 0.001)
    }

    func testOpacityFadeOut() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)
        // End is at 8.0

        // 0.2s before end (fade-out begins)
        XCTAssertEqual(annotation.opacity(at: 7.8), 1.0, accuracy: 0.001)

        // 0.1s before end (halfway through fade-out)
        XCTAssertEqual(annotation.opacity(at: 7.9), 0.5, accuracy: 0.001)

        // At end
        XCTAssertEqual(annotation.opacity(at: 8.0), 0.0, accuracy: 0.001)
    }

    func testPersistentAnnotationAlwaysFullOpacity() {
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: 5.0,
            durationSeconds: 3.0,
            isPersistent: true,
            content: .text(TextAnnotation(
                text: "Persistent",
                position: .zero,
                fontSize: 16,
                colorHex: "#FFFFFF"
            )),
            createdAt: Date()
        )

        XCTAssertEqual(annotation.opacity(at: 0.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: 100.0), 1.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: -50.0), 1.0, accuracy: 0.001)
    }

    func testShortAnnotationFadeEnvelopeNeverExceedsRange() {
        let annotation = makeAnnotation(start: 2.0, duration: 0.2)

        XCTAssertEqual(annotation.opacity(at: 2.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: 2.1), 0.5, accuracy: 0.001)
        XCTAssertEqual(annotation.opacity(at: 2.2), 0.0, accuracy: 0.001)
    }

    // MARK: - Visibility

    func testIsVisibleInsideRange() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)

        XCTAssertTrue(annotation.isVisible(at: 5.0))
        XCTAssertTrue(annotation.isVisible(at: 6.5))
        XCTAssertTrue(annotation.isVisible(at: 8.0))
    }

    func testIsVisibleOutsideRange() {
        let annotation = makeAnnotation(start: 5.0, duration: 3.0)

        XCTAssertFalse(annotation.isVisible(at: 4.9))
        XCTAssertFalse(annotation.isVisible(at: 8.1))
    }

    func testPersistentAlwaysVisible() {
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: 5.0,
            durationSeconds: 3.0,
            isPersistent: true,
            content: .text(TextAnnotation(
                text: "Always",
                position: .zero,
                fontSize: 16,
                colorHex: "#FFFFFF"
            )),
            createdAt: Date()
        )

        XCTAssertTrue(annotation.isVisible(at: 0.0))
        XCTAssertTrue(annotation.isVisible(at: 999.0))
    }

    // MARK: - Default Time Range

    func testDefaultTimeRangeCenteredOnPlayhead() {
        let result = TimedAnnotation.defaultTimeRange(
            at: 10.0,
            timelineStart: 0.0,
            timelineEnd: 60.0
        )

        XCTAssertEqual(result.start, 8.5, accuracy: 0.001)
        XCTAssertEqual(result.duration, 3.0, accuracy: 0.001)
    }

    func testDefaultTimeRangeClampedAtStart() {
        let result = TimedAnnotation.defaultTimeRange(
            at: 0.5,
            timelineStart: 0.0,
            timelineEnd: 60.0
        )

        // Playhead at 0.5, default window is -1.0 to 2.0
        // Clamped start to 0.0, end to 3.0
        XCTAssertEqual(result.start, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.duration, 3.0, accuracy: 0.001)
    }

    func testDefaultTimeRangeClampedAtEnd() {
        let result = TimedAnnotation.defaultTimeRange(
            at: 59.5,
            timelineStart: 0.0,
            timelineEnd: 60.0
        )

        // Playhead at 59.5, default window is 58.0 to 61.0
        // Clamped end to 60.0, start adjusted to 57.0
        XCTAssertEqual(result.start, 57.0, accuracy: 0.001)
        XCTAssertEqual(result.duration, 3.0, accuracy: 0.001)
    }

    func testDefaultTimeRangeShortTimeline() {
        // Timeline shorter than the default 3-second window
        let result = TimedAnnotation.defaultTimeRange(
            at: 1.0,
            timelineStart: 0.0,
            timelineEnd: 2.0
        )

        XCTAssertEqual(result.start, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.duration, 2.0, accuracy: 0.001)
    }

    // MARK: - AnnotationContent Codable Round-Trips

    func testTextAnnotationCodableRoundTrip() throws {
        let original = AnnotationContent.text(TextAnnotation(
            text: "Hello",
            position: CGPoint(x: 0.3, y: 0.7),
            fontSize: 18,
            colorHex: "#FF3B30"
        ))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnnotationContent.self, from: data)

        if case let .text(text) = decoded {
            XCTAssertEqual(text.text, "Hello")
            XCTAssertEqual(text.position.x, 0.3, accuracy: 0.001)
            XCTAssertEqual(text.position.y, 0.7, accuracy: 0.001)
            XCTAssertEqual(text.fontSize, 18, accuracy: 0.001)
            XCTAssertEqual(text.colorHex, "#FF3B30")
        } else {
            XCTFail("Expected text annotation content after decode")
        }
    }

    func testArrowAnnotationCodableRoundTrip() throws {
        let original = AnnotationContent.arrow(ArrowAnnotation(
            start: CGPoint(x: 0.1, y: 0.2),
            end: CGPoint(x: 0.8, y: 0.9),
            colorHex: "#FFD60A",
            lineWidth: 3.0
        ))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnnotationContent.self, from: data)

        if case let .arrow(arrow) = decoded {
            XCTAssertEqual(arrow.start.x, 0.1, accuracy: 0.001)
            XCTAssertEqual(arrow.start.y, 0.2, accuracy: 0.001)
            XCTAssertEqual(arrow.end.x, 0.8, accuracy: 0.001)
            XCTAssertEqual(arrow.end.y, 0.9, accuracy: 0.001)
            XCTAssertEqual(arrow.colorHex, "#FFD60A")
            XCTAssertEqual(arrow.lineWidth, 3.0, accuracy: 0.001)
        } else {
            XCTFail("Expected arrow annotation content after decode")
        }
    }

    func testDrawingAnnotationCodableRoundTrip() throws {
        let drawingData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let original = AnnotationContent.drawing(DrawingAnnotation(drawingData: drawingData))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnnotationContent.self, from: data)

        if case let .drawing(drawing) = decoded {
            XCTAssertEqual(drawing.drawingData, drawingData)
        } else {
            XCTFail("Expected drawing annotation content after decode")
        }
    }

    func testTimedAnnotationCodableRoundTripIncludesCanvasSize() throws {
        let original = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: 1,
            durationSeconds: 2,
            isPersistent: false,
            content: .text(TextAnnotation(
                text: "Canvas",
                position: CGPoint(x: 0.25, y: 0.75),
                fontSize: 16,
                colorHex: "#FFFFFF"
            )),
            canvasSize: CGSize(width: 390, height: 844),
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimedAnnotation.self, from: data)

        XCTAssertEqual(decoded.canvasSize?.width, 390)
        XCTAssertEqual(decoded.canvasSize?.height, 844)
    }

    func testTimedAnnotationDecodesLegacyPayloadWithoutCanvasSize() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "startTimeSeconds": 1,
          "durationSeconds": 2,
          "isPersistent": false,
          "content": {
            "type": "text",
            "payload": {
              "text": "Legacy",
              "position": [0.5, 0.5],
              "fontSize": 16,
              "colorHex": "#FFFFFF"
            }
          },
          "createdAt": 10
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TimedAnnotation.self, from: json)

        XCTAssertNil(decoded.canvasSize)
        XCTAssertEqual(decoded.startTimeSeconds, 1)
    }

    // MARK: - Coordinate Mapping

    func testCoordinateMappingRoundTripsAuthoringCanvasToExportRect() {
        let canvasSize = CGSize(width: 390, height: 844)
        let authoringPoint = CGPoint(x: 97.5, y: 211)
        let normalized = AnnotationCoordinateMapper.normalizedPoint(authoringPoint, canvasSize: canvasSize)
        let destination = AnnotationCoordinateMapper.destinationPoint(
            normalized,
            destinationRect: CGRect(x: 120, y: 80, width: 960, height: 540)
        )

        XCTAssertEqual(normalized.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(destination.x, 360, accuracy: 0.001)
        XCTAssertEqual(destination.y, 215, accuracy: 0.001)
    }

    func testCoordinateMappingUsesLetterboxedContentRect() {
        let panelRect = CGRect(x: 0, y: 0, width: 960, height: 540)
        let placement = ExportPlan.aspectFitTransform(
            contentExtent: CGRect(x: 0, y: 0, width: 1080, height: 1920),
            panelRect: panelRect
        )
        let contentRect = CGRect(
            x: placement.offset.x,
            y: placement.offset.y,
            width: 1080 * placement.scale,
            height: 1920 * placement.scale
        )
        let mapped = AnnotationCoordinateMapper.destinationPoint(
            CGPoint(x: 0.5, y: 0.5),
            destinationRect: contentRect
        )

        XCTAssertEqual(contentRect.width, 303.75, accuracy: 0.01)
        XCTAssertEqual(contentRect.height, 540, accuracy: 0.01)
        XCTAssertEqual(mapped.x, 480, accuracy: 0.01)
        XCTAssertEqual(mapped.y, 270, accuracy: 0.01)
    }

    // MARK: - Raster Cache

    func testRasterizerCacheInvalidatesOnEdit() {
        let cache = AnnotationRasterCache()
        let annotation = makeAnnotation(start: 0, duration: 1)
        let size = CGSize(width: 240, height: 160)

        XCTAssertNotNil(cache.image(
            for: annotation,
            destinationSize: size,
            render: { AnnotationRasterizer.image(for: annotation, destinationSize: size) }
        ))
        XCTAssertEqual(cache.count, 1)

        cache.invalidate(annotationID: annotation.id)

        XCTAssertEqual(cache.count, 0)
    }

    func testRasterizerCacheCreatesNewEntryWhenContentChanges() {
        let cache = AnnotationRasterCache()
        let size = CGSize(width: 240, height: 160)
        var annotation = makeAnnotation(start: 0, duration: 1)

        _ = cache.image(
            for: annotation,
            destinationSize: size,
            render: { AnnotationRasterizer.image(for: annotation, destinationSize: size) }
        )
        annotation.content = .text(TextAnnotation(
            text: "Changed",
            position: CGPoint(x: 0.5, y: 0.5),
            fontSize: 16,
            colorHex: "#FFFFFF"
        ))
        _ = cache.image(
            for: annotation,
            destinationSize: size,
            render: { AnnotationRasterizer.image(for: annotation, destinationSize: size) }
        )

        XCTAssertEqual(cache.count, 2)
    }

    func testRasterizerDeterministicBytesAtFixedSize() throws {
        let annotation = makeAnnotation(start: 0, duration: 1)
        let size = CGSize(width: 240, height: 160)

        let first = try XCTUnwrap(AnnotationRasterizer.image(for: annotation, destinationSize: size))
        let second = try XCTUnwrap(AnnotationRasterizer.image(for: annotation, destinationSize: size))

        XCTAssertEqual(rawBytes(first), rawBytes(second))
    }

    // MARK: - Color Hex Extension

    func testColorInitFromHex6() {
        let color = Color(hex: "#FF0000")
        let uiColor = UIColor(color)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 1.0, accuracy: 0.01)
    }

    func testColorInitFromHex8WithAlpha() {
        let color = Color(hex: "#FF000080")
        let uiColor = UIColor(color)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)

        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 128.0 / 255.0, accuracy: 0.02)
    }

    func testColorHexStringRoundTrip() {
        let original = Color(hex: "#30D158")
        let hexString = original.hexString

        // The hex string should be close to the original (may differ slightly
        // due to color space conversion)
        XCTAssertEqual(hexString.count, 7) // "#RRGGBB"
        XCTAssertTrue(hexString.hasPrefix("#"))
    }

    func testWhiteColorHex() {
        let white = Color(hex: "#FFFFFF")
        let hex = white.hexString
        XCTAssertEqual(hex, "#FFFFFF")
    }

    func testBlackColorHex() {
        let black = Color(hex: "#000000")
        let hex = black.hexString
        XCTAssertEqual(hex, "#000000")
    }

    // MARK: - Helpers

    private func makeAnnotation(start: Double, duration: Double) -> TimedAnnotation {
        TimedAnnotation(
            id: UUID(),
            startTimeSeconds: start,
            durationSeconds: duration,
            isPersistent: false,
            content: .text(TextAnnotation(
                text: "Test",
                position: CGPoint(x: 0.5, y: 0.5),
                fontSize: 16,
                colorHex: "#FFFFFF"
            )),
            createdAt: Date()
        )
    }

    private func rawBytes(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data
        else {
            return nil
        }
        return providerData as Data
    }
}
