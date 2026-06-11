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

            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }

                let floats = try extractFloats(from: sampleBuffer)
                allSamples.append(contentsOf: floats)
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

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(kCMBlockBufferNoErr + 1)
            }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }

        guard status == kCMBlockBufferNoErr else {
            throw AudioExtractionError.readFailed
        }

        let floats: [Float] = data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }

        return floats
    }
}
