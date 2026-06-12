// CropGeometry.swift
// Coreo
//
// Shared normalized crop-rect conversions used by preview and export.

import CoreGraphics

/// Pure crop geometry helpers shared between preview and export paths.
enum CropGeometry {
    /// Clamps a top-left-origin normalized crop rect to the unit square.
    ///
    /// - Parameter rect: Proposed normalized crop rectangle.
    /// - Returns: A positive-area crop rect, or nil when the rect is unusable.
    static func normalizedCropRect(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// Converts a normalized top-left crop rect into CIImage coordinates.
    ///
    /// - Parameters:
    ///   - cropRect: Normalized crop rectangle, origin at top-left.
    ///   - extent: Display-oriented CIImage extent, origin at bottom-left.
    /// - Returns: Crop rectangle in CIImage coordinates, or nil for unusable input.
    static func ciCropRect(for cropRect: CGRect?, extent: CGRect) -> CGRect? {
        guard let cropRect = normalizedCropRect(cropRect), extent.width > 0, extent.height > 0 else {
            return nil
        }

        return CGRect(
            x: extent.origin.x + cropRect.minX * extent.width,
            y: extent.origin.y + (1 - cropRect.maxY) * extent.height,
            width: cropRect.width * extent.width,
            height: cropRect.height * extent.height
        )
    }

    /// Converts a normalized crop rect to a layer contents rect for preview.
    ///
    /// - Parameter cropRect: Normalized crop rectangle, origin at top-left.
    /// - Returns: Unit contents rect for AVPlayerLayer/CALayer preview cropping.
    static func previewContentsRect(for cropRect: CGRect?) -> CGRect {
        normalizedCropRect(cropRect) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
