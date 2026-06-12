// PanelCompositor.swift
// Coreo
//
// Custom AVVideoCompositing that composites multi-angle videos into a
// split-screen layout with explicit per-panel clipping. Replaces the
// default layer-instruction approach which has no built-in clipping and
// can cause tracks to bleed into adjacent panels.

@preconcurrency import AVFoundation
import CoreImage

// MARK: - AnnotationFrameRendering

/// Extension point for Wave 5 per-frame annotation rendering.
protocol AnnotationFrameRendering: Sendable {
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
    ) -> CIImage
}

/// No-op annotation renderer used until Wave 5 plugs in real overlays.
struct EmptyAnnotationFrameRenderer: AnnotationFrameRendering {
    /// Returns the frame unchanged.
    ///
    /// - Parameters:
    ///   - image: Current composited frame.
    ///   - time: Composition time for the frame.
    ///   - renderSize: Output render size.
    /// - Returns: The unchanged frame image.
    func renderAnnotations(
        over image: CIImage,
        at _: CMTime,
        renderSize _: CGSize
    ) -> CIImage {
        image
    }
}

// MARK: - PanelCompositionInstruction

/// Custom video composition instruction carrying per-panel layout data.
/// Each panel maps one composition track to a clipped rectangle in the output.
final class PanelCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// Per-panel rendering configuration.
    struct PanelConfig {
        /// Composition track ID for this panel's video source.
        let trackID: CMPersistentTrackID
        /// Panel rectangle in render coordinates (y-down, points).
        let panelRect: CGRect
        /// Corrected (post-rotation) video dimensions.
        let videoSize: CGSize
        /// The source track's preferredTransform (rotation + translation).
        let sourceTransform: CGAffineTransform
        /// Optional normalized (0-1) user crop rect.
        let cropRect: CGRect?
    }

    let panelConfigs: [PanelConfig]
    let renderSize: CGSize
    let bgRed: CGFloat
    let bgGreen: CGFloat
    let bgBlue: CGFloat
    let annotationRenderer: any AnnotationFrameRendering

    init(
        timeRange: CMTimeRange,
        panelConfigs: [PanelConfig],
        renderSize: CGSize,
        annotationRenderer: any AnnotationFrameRendering = EmptyAnnotationFrameRenderer(),
        bgRed: CGFloat = 10.0 / 255.0,
        bgGreen: CGFloat = 10.0 / 255.0,
        bgBlue: CGFloat = 10.0 / 255.0
    ) {
        self.timeRange = timeRange
        self.panelConfigs = panelConfigs
        self.renderSize = renderSize
        self.bgRed = bgRed
        self.bgGreen = bgGreen
        self.bgBlue = bgBlue
        self.annotationRenderer = annotationRenderer
        requiredSourceTrackIDs = panelConfigs.map {
            NSNumber(value: $0.trackID) as NSValue
        }
        super.init()
    }
}

// MARK: - PanelCompositor

/// CIImage-based compositor that renders each video into its designated
/// panel with explicit clipping. Handles rotation, aspect-fit scaling,
/// and optional crop rects.
final class PanelCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let renderQueue = DispatchQueue(
        label: "com.coreo.panel-compositor",
        qos: .userInitiated
    )

    // MARK: AVVideoCompositing Protocol

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [self] in
            compositeFrame(request)
        }
    }

    // MARK: - Compositing

    private func compositeFrame(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction
            as? PanelCompositionInstruction
        else {
            request.finish(with: NSError(
                domain: "PanelCompositor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown instruction type"]
            ))
            return
        }

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(
                domain: "PanelCompositor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate output buffer"]
            ))
            return
        }

        let renderSize = instruction.renderSize
        let renderH = renderSize.height

        // Background fills the entire output.
        let bgColor = CIColor(
            red: instruction.bgRed,
            green: instruction.bgGreen,
            blue: instruction.bgBlue
        )
        var result = CIImage(color: bgColor)
            .cropped(to: CGRect(origin: .zero, size: renderSize))

        // Composite each panel (first config = bottommost, last = topmost).
        for config in instruction.panelConfigs {
            guard let sourceBuffer = request.sourceFrame(byTrackID: config.trackID) else {
                continue
            }

            // Orient the raw pixel buffer to correct display orientation.
            var image = CIImage(cvPixelBuffer: sourceBuffer)
            let orientation = Self.orientation(from: config.sourceTransform)
            image = image.oriented(orientation)

            // Image extent is now in display orientation (y-up, CIImage coords).
            if let cropRect = CropGeometry.ciCropRect(for: config.cropRect, extent: image.extent) {
                image = image.cropped(to: cropRect)
            }

            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { continue }

            // Convert panel rect from screen (y-down) to CIImage (y-up).
            let ciPanel = CGRect(
                x: config.panelRect.origin.x,
                y: renderH - config.panelRect.origin.y - config.panelRect.height,
                width: config.panelRect.width,
                height: config.panelRect.height
            )

            let placement = ExportPlan.aspectFitTransform(
                contentExtent: extent,
                panelRect: ciPanel
            )

            // Move image origin to (0,0), scale, then position in panel.
            image = image.transformed(by: CGAffineTransform(
                translationX: -extent.origin.x,
                y: -extent.origin.y
            ))
            image = image.transformed(by: CGAffineTransform(
                scaleX: placement.scale, y: placement.scale
            ))
            image = image.transformed(by: CGAffineTransform(
                translationX: placement.offset.x,
                y: placement.offset.y
            ))

            // Clip to panel bounds — the key operation that prevents bleed.
            image = image.cropped(to: ciPanel)

            // Layer over the current result.
            result = image.composited(over: result)
        }

        result = instruction.annotationRenderer.renderAnnotations(
            over: result,
            at: request.compositionTime,
            renderSize: renderSize
        )

        ciContext.render(result, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    // MARK: - Orientation Mapping

    /// Converts a video track's preferredTransform to a CGImagePropertyOrientation.
    /// Handles the four standard iPhone recording orientations.
    static func orientation(
        from transform: CGAffineTransform
    ) -> CGImagePropertyOrientation {
        let a = round(transform.a)
        let b = round(transform.b)
        let c = round(transform.c)
        let d = round(transform.d)

        if a == 0, b == 1, c == -1, d == 0 {
            return .right // 90° CW  — portrait, home bottom
        } else if a == 0, b == -1, c == 1, d == 0 {
            return .left // 90° CCW — portrait, home top
        } else if a == -1, b == 0, c == 0, d == -1 {
            return .down // 180°    — landscape, home left
        } else {
            return .up // 0°      — landscape, home right
        }
    }
}
