// AudioExtractor.swift
// Coreo
//
// Extracts audio from a video file as a mono PCM float array, downsampled
// to an efficient rate for cross-correlation. The 8 kHz default is more than
// sufficient for music-based sync and keeps FFT sizes small.

import AVFoundation
import Accelerate

/// Errors that can occur during audio extraction from video.
enum AudioExtractionError: Error, LocalizedError {
    case noAudioTrack
    case readerInitFailed
    case readFailed
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "The video file does not contain an audio track."
        case .readerInitFailed:
            return "Failed to initialize the audio reader for the video file."
        case .readFailed:
            return "Failed to read audio samples from the video file."
        case .emptyAudio:
            return "The audio track contains no samples."
        }
    }
}

/// Extracts audio from video files as raw PCM float arrays for analysis.
///
/// The extraction configures AVAssetReaderTrackOutput to deliver mono,
/// Float32 samples at the target sample rate. AVFoundation handles the
/// format conversion and downsampling internally, which is both simpler
/// and faster than manual resampling with Accelerate.
enum AudioExtractor {

    /// Extract audio from a video asset as a mono PCM float array.
    ///
    /// - Parameters:
    ///   - url: URL to the video file (.mp4, .mov, .m4v).
    ///   - targetSampleRate: Desired output sample rate in Hz. Default 8000 Hz
    ///     is sufficient for music correlation and keeps FFT sizes small.
    /// - Returns: Array of Float32 samples representing the mono audio waveform.
    /// - Throws: `AudioExtractionError` if the file has no audio or reading fails.
    static func extractPCM(from url: URL, targetSampleRate: Double = 8000) async throws -> [Float] {
        let asset = AVURLAsset(url: url)

        // Load audio tracks — must use the async load API (iOS 16+).
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioExtractionError.noAudioTrack
        }
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let estimatedSampleCount = durationSeconds.isFinite && durationSeconds > 0
            ? Int((durationSeconds * targetSampleRate).rounded(.up))
            : 8_192

        // Configure output format: mono Float32 at the target sample rate.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: targetSampleRate
        ]

        // Build the reader on a background thread to keep the main thread free.
        let samples: [Float] = try await Task.detached(priority: .userInitiated) {
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw AudioExtractionError.readerInitFailed
            }

            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else {
                throw AudioExtractionError.readerInitFailed
            }
            reader.add(output)

            guard reader.startReading() else {
                throw AudioExtractionError.readFailed
            }

            // Read all sample buffers and concatenate into one Float array.
            var allSamples: [Float] = []
            allSamples.reserveCapacity(max(estimatedSampleCount, 8_192))

            while reader.status == .reading {
                try Task.checkCancellation()

                var extractedSamples: [Float] = []
                var extractionError: Error?
                let shouldContinue = autoreleasepool {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        return false
                    }

                    do {
                        extractedSamples = try extractFloats(from: sampleBuffer)
                    } catch {
                        extractionError = error
                    }
                    return true
                }

                if let extractionError {
                    throw extractionError
                }
                guard shouldContinue else {
                    break
                }

                allSamples.append(contentsOf: extractedSamples)
            }

            if reader.status == .failed {
                throw AudioExtractionError.readFailed
            }

            guard !allSamples.isEmpty else {
                throw AudioExtractionError.emptyAudio
            }

            return allSamples
        }.value

        return samples
    }

    // MARK: - Private

    /// Extract Float32 samples from a CMSampleBuffer containing audio data.
    ///
    /// Accesses the underlying audio buffer list and copies the float samples
    /// out into a Swift array. The buffer is expected to contain interleaved
    /// mono Float32 data (one channel, as configured in our output settings).
    ///
    /// - Parameter sampleBuffer: A CMSampleBuffer from an AVAssetReaderTrackOutput.
    /// - Returns: Array of Float32 samples from this buffer.
    /// - Throws: `AudioExtractionError.readFailed` if the buffer can't be accessed.
    private static func extractFloats(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw AudioExtractionError.readFailed
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        let sampleCount = length / MemoryLayout<Float>.size

        guard sampleCount > 0 else {
            return []
        }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        var totalLength = 0
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        if pointerStatus == kCMBlockBufferNoErr,
           let dataPointer,
           totalLength >= length,
           lengthAtOffset >= length {
            return [Float](unsafeUninitializedCapacity: sampleCount) { buffer, initializedCount in
                let source = UnsafeRawBufferPointer(start: dataPointer, count: length)
                let floats = source.bindMemory(to: Float.self)
                guard let destination = buffer.baseAddress else {
                    initializedCount = 0
                    return
                }
                destination.initialize(from: floats.baseAddress!, count: sampleCount)
                initializedCount = sampleCount
            }
        }

        return try [Float](unsafeUninitializedCapacity: sampleCount) { buffer, initializedCount in
            guard let baseAddress = buffer.baseAddress else {
                initializedCount = 0
                throw AudioExtractionError.readFailed
            }
            let status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
            guard status == kCMBlockBufferNoErr else {
                initializedCount = 0
                throw AudioExtractionError.readFailed
            }
            initializedCount = sampleCount
        }
    }
}
