// EndBumperGenerator.swift
// Coreo
//
// Generates the 1-second branded end card appended to every export.
// Uses AVAssetWriter with a CVPixelBuffer adaptor to write 30 frames
// of the "Coreo" title over a dark background with a fade-in/hold/fade-out
// opacity curve. No audio track — the bumper is silent.

import AVFoundation
import CoreGraphics
import UIKit

/// Errors that can occur during bumper generation.
enum BumperError: Error, LocalizedError {
    case writerCreationFailed(String)
    case pixelBufferFailed
    case writingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .writerCreationFailed(reason):
            "Failed to create bumper writer: \(reason)"
        case .pixelBufferFailed:
            "Failed to create pixel buffer for bumper frame."
        case let .writingFailed(reason):
            "Bumper writing failed: \(reason)"
        }
    }
}

/// Generates a 1-second branded end bumper video file.
///
/// The bumper displays "Coreo" centered on a dark (#0A0A0A) background,
/// rendered in white SF Pro Medium. The text fades in over 0.3s, holds,
/// then fades out over 0.3s. Output is a silent .mp4 at 30fps.
enum EndBumperGenerator {
    /// Total bumper duration in seconds.
    private static let durationSeconds: Double = 1.0

    /// Background color matching the app's dark theme.
    private static let backgroundColor = CGColor(
        srgbRed: 10.0 / 255.0,
        green: 10.0 / 255.0,
        blue: 10.0 / 255.0,
        alpha: 1.0
    )
    private static var cachedBumpers: [String: URL] = [:]
    private static let cacheLock = NSLock()

    // MARK: - Public

    /// Generates a 1-second end bumper video.
    ///
    /// The file is written to a temporary directory and its URL returned.
    /// The caller is responsible for cleanup after incorporating the bumper
    /// into the final export composition.
    ///
    /// - Parameter resolution: Video resolution. Defaults to 1920x1080.
    /// - Returns: URL to the generated bumper .mp4 file.
    /// - Throws: `BumperError` if pixel buffer or writer operations fail.
    static func generate(
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        fps: Int32 = 30
    ) async throws -> URL {
        let cacheKey = "\(Int(resolution.width))x\(Int(resolution.height))@\(fps)"
        if let cached = cachedURL(for: cacheKey) {
            return cached
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreo_bumper_\(UUID().uuidString).mp4")

        // Clean up any leftover file at this path.
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try createWriter(outputURL: outputURL, resolution: resolution)
        let writerInput = createWriterInput(resolution: resolution)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes(resolution: resolution)
        )

        writer.add(writerInput)

        guard writer.startWriting() else {
            let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
            throw BumperError.writerCreationFailed(errorMsg)
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(durationSeconds * Double(fps))

        // Write frames
        for frameIndex in 0 ..< totalFrames {
            try Task.checkCancellation()
            // Wait for the writer input to be ready.
            var waitIterations = 0
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed || writer.status == .cancelled {
                    let errorMsg = writer.error?.localizedDescription ?? "Writer stopped."
                    throw BumperError.writingFailed(errorMsg)
                }
                waitIterations += 1
                if waitIterations > 500 {
                    writer.cancelWriting()
                    throw BumperError.writingFailed("Timed out waiting for the bumper writer.")
                }
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            let presentationTime = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: fps
            )
            let opacity = opacityForFrame(frameIndex, totalFrames: totalFrames, fps: fps)

            guard let pixelBuffer = try createFrame(
                resolution: resolution,
                textOpacity: opacity,
                pool: adaptor.pixelBufferPool
            ) else {
                throw BumperError.pixelBufferFailed
            }

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
                throw BumperError.writingFailed(errorMsg)
            }
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
            throw BumperError.writingFailed(errorMsg)
        }

        storeCachedURL(outputURL, for: cacheKey)
        return outputURL
    }

    // MARK: - Writer Setup

    /// Creates an AVAssetWriter configured for H.264 .mp4 output.
    ///
    /// - Parameters:
    ///   - outputURL: File URL for the output.
    ///   - resolution: Video dimensions.
    /// - Returns: A configured AVAssetWriter.
    private static func createWriter(
        outputURL: URL,
        resolution _: CGSize
    ) throws -> AVAssetWriter {
        do {
            return try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw BumperError.writerCreationFailed(error.localizedDescription)
        }
    }

    /// Creates an AVAssetWriterInput configured for H.264 video.
    ///
    /// - Parameter resolution: Video dimensions.
    /// - Returns: A configured writer input.
    private static func createWriterInput(resolution: CGSize) -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(resolution.width),
            AVVideoHeightKey: Int(resolution.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// Pixel buffer attributes for the adaptor.
    private static func pixelBufferAttributes(resolution: CGSize) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(resolution.width),
            kCVPixelBufferHeightKey as String: Int(resolution.height)
        ]
    }

    // MARK: - Frame Rendering

    /// Calculates text opacity for a given frame index.
    ///
    /// Fade curve: 0-9 fade in, 10-20 hold at 1.0, 21-29 fade out.
    ///
    /// - Parameters:
    ///   - frameIndex: Current frame (0-based).
    ///   - totalFrames: Total number of frames.
    /// - Returns: Opacity from 0.0 to 1.0.
    private static func opacityForFrame(
        _ frameIndex: Int,
        totalFrames: Int,
        fps: Int32
    ) -> CGFloat {
        let fadeInFrames = Int(0.3 * Double(fps)) // 9 frames
        let fadeOutFrames = Int(0.3 * Double(fps)) // 9 frames
        let fadeOutStart = totalFrames - fadeOutFrames

        if frameIndex < fadeInFrames {
            return CGFloat(frameIndex) / CGFloat(fadeInFrames)
        } else if frameIndex >= fadeOutStart {
            let remaining = totalFrames - frameIndex
            return CGFloat(remaining) / CGFloat(fadeOutFrames)
        } else {
            return 1.0
        }
    }

    /// Renders a single bumper frame as a CVPixelBuffer.
    ///
    /// Draws the dark background and centered "Coreo" text at the given opacity.
    ///
    /// - Parameters:
    ///   - resolution: Frame dimensions.
    ///   - textOpacity: Opacity for the title text (0.0-1.0).
    ///   - pool: Optional pixel buffer pool from the adaptor (preferred for performance).
    /// - Returns: A rendered CVPixelBuffer, or nil on failure.
    private static func createFrame(
        resolution: CGSize,
        textOpacity: CGFloat,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        if let pool {
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, pixelBuffer != nil else {
                return nil
            }
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            let status = CVPixelBufferCreate(
                nil,
                Int(resolution.width),
                Int(resolution.height),
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, pixelBuffer != nil else {
                return nil
            }
        }

        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = Int(resolution.width)
        let height = Int(resolution.height)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        // Draw dark background
        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw "Coreo" text centered
        drawBumperText(
            in: context,
            resolution: resolution,
            opacity: textOpacity
        )

        return buffer
    }

    /// Draws the "Coreo" title text centered in the Core Graphics context.
    ///
    /// - Parameters:
    ///   - context: The CG context to draw into.
    ///   - resolution: Frame dimensions.
    ///   - opacity: Text opacity.
    private static func drawBumperText(
        in context: CGContext,
        resolution: CGSize,
        opacity: CGFloat
    ) {
        let text = "Coreo" as NSString

        // Scale font size relative to resolution height (40pt at 1080p).
        let fontSize = resolution.height * (40.0 / 1080.0)

        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(opacity)
        ]

        let textSize = text.size(withAttributes: attributes)
        let textRect = CGRect(
            x: (resolution.width - textSize.width) / 2,
            y: (resolution.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        // UIKit text drawing needs a pushed UIGraphics context.
        UIGraphicsPushContext(context)

        // Flip the context for UIKit text rendering (CGContext is bottom-up).
        context.saveGState()
        context.translateBy(x: 0, y: resolution.height)
        context.scaleBy(x: 1, y: -1)

        text.draw(in: textRect, withAttributes: attributes)

        context.restoreGState()
        UIGraphicsPopContext()
    }

    /// Returns a cached bumper URL if the file still exists.
    ///
    /// - Parameter key: Cache key for resolution and frame rate.
    /// - Returns: Existing bumper URL, or nil if none is cached.
    private static func cachedURL(for key: String) -> URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let url = cachedBumpers[key],
              FileManager.default.fileExists(atPath: url.path)
        else {
            cachedBumpers[key] = nil
            return nil
        }
        return url
    }

    /// Stores a generated bumper URL in the in-memory cache.
    ///
    /// - Parameters:
    ///   - url: Generated bumper file URL.
    ///   - key: Cache key for resolution and frame rate.
    private static func storeCachedURL(_ url: URL, for key: String) {
        cacheLock.lock()
        cachedBumpers[key] = url
        cacheLock.unlock()
    }
}
