// AnnotationRasterizerSnapshotTests.swift
// CoreoTests
//
// Snapshot references are valid only on iPhone 17 Pro, OS=26.5.

@testable import Coreo
import PencilKit
import SnapshotTesting
import XCTest

@MainActor
final class AnnotationRasterizerSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record = .never
    private let authoringCanvas = CGSize(width: 200, height: 120)
    private let widePanel = CGSize(width: 384, height: 216)
    private let portraitPanel = CGSize(width: 216, height: 384)
    private let snapshotScale: CGFloat = 2.0

    /// Runs each snapshot under a fixed light-mode trait collection.
    override func invokeTest() {
        withSnapshotTesting(record: recordMode) {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                super.invokeTest()
            }
        }
    }

    /// Snapshots a deterministic multi-stroke PencilKit drawing raster.
    func testDrawingAnnotationRaster() throws {
        let image = try rasterImage(for: Fixtures.drawingAnnotation(canvasSize: authoringCanvas), destinationSize: widePanel)

        assertSnapshot(of: image, as: imageStrategy, named: "multi-stroke-drawing")
    }

    /// Snapshots a text annotation rendered with the system semibold font.
    func testTextAnnotationRaster() throws {
        let image = try rasterImage(for: Fixtures.textAnnotation(canvasSize: authoringCanvas), destinationSize: widePanel)

        assertSnapshot(of: image, as: imageStrategy, named: "system-font-text")
    }

    /// Snapshots arrow shaft and closed-head geometry from the shared rasterizer.
    func testArrowAnnotationRaster() throws {
        let image = try rasterImage(for: Fixtures.arrowAnnotation(canvasSize: authoringCanvas), destinationSize: widePanel)

        assertSnapshot(of: image, as: imageStrategy, named: "arrow-head-and-shaft")
    }

    /// Snapshots drawing, arrow, and text annotations composited on one canvas.
    func testComposedAnnotationsRaster() throws {
        let image = try composedImage(
            annotations: Fixtures.allAnnotations(canvasSize: authoringCanvas),
            destinationSize: widePanel,
            currentTimeSeconds: 1.0
        )

        assertSnapshot(of: image, as: imageStrategy, named: "composition-all-types")
    }

    /// Snapshots the same annotation at mid fade-in and full opacity.
    func testFadeEnvelopeMidFadeInAndFullyVisible() throws {
        let annotation = Fixtures.textAnnotation(canvasSize: authoringCanvas)
        let midFade = try composedImage(
            annotations: [annotation],
            destinationSize: widePanel,
            currentTimeSeconds: 0.1
        )
        let fullyVisible = try composedImage(
            annotations: [annotation],
            destinationSize: widePanel,
            currentTimeSeconds: 1.0
        )

        assertSnapshot(of: midFade, as: imageStrategy, named: "fade-envelope-mid-fade-in")
        assertSnapshot(of: fullyVisible, as: imageStrategy, named: "fade-envelope-fully-visible")
    }

    /// Snapshots the same annotation set on wide and portrait panel geometries.
    func testSameAnnotationsOnWideAndPortraitPanelGeometry() throws {
        let annotations = Fixtures.allAnnotations(canvasSize: authoringCanvas)
        let wideImage = try composedImage(
            annotations: annotations,
            destinationSize: widePanel,
            currentTimeSeconds: 1.0
        )
        let portraitImage = try composedImage(
            annotations: annotations,
            destinationSize: portraitPanel,
            currentTimeSeconds: 1.0
        )

        assertSnapshot(of: wideImage, as: imageStrategy, named: "geometry-wide-16x9-panel")
        assertSnapshot(of: portraitImage, as: imageStrategy, named: "geometry-portrait-letterbox-panel")
    }

    /// Image comparison settings for raster snapshots.
    private var imageStrategy: Snapshotting<UIImage, UIImage> {
        .image(precision: 0.995, perceptualPrecision: 0.995)
    }

    /// Renders one annotation through `AnnotationRasterizer`.
    private func rasterImage(for annotation: TimedAnnotation, destinationSize: CGSize) throws -> UIImage {
        let image = try XCTUnwrap(AnnotationRasterizer.image(for: annotation, destinationSize: destinationSize))
        return scaledSnapshotImage(image)
    }

    /// Composites rasterized annotations over the export background with fade opacity applied.
    private func composedImage(
        annotations: [TimedAnnotation],
        destinationSize: CGSize,
        currentTimeSeconds: Double
    ) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = snapshotScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: destinationSize, format: format)

        return renderer.image { _ in
            UIColor(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: destinationSize))

            for annotation in annotations {
                let opacity = annotation.opacity(at: currentTimeSeconds)
                guard opacity > 0,
                      let image = AnnotationRasterizer.image(for: annotation, destinationSize: destinationSize)
                else {
                    continue
                }
                image.draw(
                    in: CGRect(origin: .zero, size: destinationSize),
                    blendMode: .normal,
                    alpha: CGFloat(opacity)
                )
            }
        }
    }

    /// Tags a production raster with the configured snapshot scale.
    private func scaledSnapshotImage(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: snapshotScale, orientation: image.imageOrientation)
    }
}

private enum Fixtures {
    private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// Returns the complete deterministic annotation fixture set.
    static func allAnnotations(canvasSize: CGSize) -> [TimedAnnotation] {
        [
            drawingAnnotation(canvasSize: canvasSize),
            arrowAnnotation(canvasSize: canvasSize),
            textAnnotation(canvasSize: canvasSize)
        ]
    }

    /// Returns a multi-stroke drawing annotation fixture.
    static func drawingAnnotation(canvasSize: CGSize) -> TimedAnnotation {
        TimedAnnotation(
            id: uuid("11111111-1111-1111-1111-111111111111"),
            startTimeSeconds: 0,
            durationSeconds: 3,
            isPersistent: false,
            content: .drawing(DrawingAnnotation(drawingData: drawingData())),
            canvasSize: canvasSize,
            createdAt: createdAt
        )
    }

    /// Returns a system-font text annotation fixture.
    static func textAnnotation(canvasSize: CGSize) -> TimedAnnotation {
        TimedAnnotation(
            id: uuid("22222222-2222-2222-2222-222222222222"),
            startTimeSeconds: 0,
            durationSeconds: 3,
            isPersistent: false,
            content: .text(TextAnnotation(
                text: "Coreo",
                position: CGPoint(x: 0.52, y: 0.32),
                fontSize: 18,
                colorHex: "#FFFFFF"
            )),
            canvasSize: canvasSize,
            createdAt: createdAt
        )
    }

    /// Returns an arrow annotation fixture.
    static func arrowAnnotation(canvasSize: CGSize) -> TimedAnnotation {
        TimedAnnotation(
            id: uuid("33333333-3333-3333-3333-333333333333"),
            startTimeSeconds: 0,
            durationSeconds: 3,
            isPersistent: false,
            content: .arrow(ArrowAnnotation(
                start: CGPoint(x: 0.18, y: 0.78),
                end: CGPoint(x: 0.75, y: 0.55),
                colorHex: "#FF6B35",
                lineWidth: 5
            )),
            canvasSize: canvasSize,
            createdAt: createdAt
        )
    }

    /// Serializes the deterministic PencilKit drawing fixture.
    private static func drawingData() -> Data {
        let strokes = [
            stroke(
                color: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1),
                width: 5,
                points: [
                    CGPoint(x: 24, y: 26),
                    CGPoint(x: 60, y: 44),
                    CGPoint(x: 92, y: 34),
                    CGPoint(x: 130, y: 58)
                ]
            ),
            stroke(
                color: UIColor(red: 0.39, green: 0.82, blue: 1, alpha: 1),
                width: 4,
                points: [
                    CGPoint(x: 40, y: 92),
                    CGPoint(x: 78, y: 76),
                    CGPoint(x: 122, y: 88),
                    CGPoint(x: 168, y: 68)
                ]
            )
        ]
        return PKDrawing(strokes: strokes).dataRepresentation()
    }

    /// Creates one deterministic PencilKit stroke.
    private static func stroke(color: UIColor, width: CGFloat, points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.05,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: createdAt)
        let ink = PKInk(.pen, color: color)
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }

    /// Parses a literal UUID fixture value.
    private static func uuid(_ string: String) -> UUID {
        guard let value = UUID(uuidString: string) else {
            fatalError("Invalid fixture UUID: \(string)")
        }
        return value
    }
}
