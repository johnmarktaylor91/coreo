// ModelTests.swift
// CoreoTests
//
// Unit tests for CoreoProject and VideoAsset serialization and
// timeline computation.

import XCTest
@testable import Coreo

final class ModelTests: XCTestCase {

    // MARK: - VideoAsset Round-Trip

    func testVideoAssetJSONRoundTrip() throws {
        let original = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/test_video.mp4"),
            durationSeconds: 125.5,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: Data([0x01, 0x02, 0x03])
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VideoAsset.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.localURL, original.localURL)
        XCTAssertEqual(decoded.durationSeconds, original.durationSeconds, accuracy: 0.001)
        XCTAssertEqual(decoded.dimensions.width, original.dimensions.width, accuracy: 0.001)
        XCTAssertEqual(decoded.dimensions.height, original.dimensions.height, accuracy: 0.001)
        XCTAssertEqual(decoded.audioBitrate, original.audioBitrate)
        XCTAssertEqual(decoded.audioSampleRate, original.audioSampleRate)
        XCTAssertEqual(decoded.thumbnailData, original.thumbnailData)
    }

    func testVideoAssetWithNilThumbnailRoundTrip() throws {
        let original = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/test.mov"),
            durationSeconds: 60.0,
            dimensions: CGSize(width: 3840, height: 2160),
            audioBitrate: 256_000,
            audioSampleRate: 48000,
            thumbnailData: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoAsset.self, from: data)

        XCTAssertNil(decoded.thumbnailData)
        XCTAssertEqual(decoded.durationSeconds, 60.0, accuracy: 0.001)
    }

    func testVideoAssetFormattedDuration() {
        let asset = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/v.mp4"),
            durationSeconds: 83.45,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )

        XCTAssertEqual(asset.formattedDuration, "1:23")
    }

    // MARK: - CoreoProject Round-Trip

    func testCoreProjectJSONRoundTrip() throws {
        let video1 = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/a.mp4"),
            durationSeconds: 30.0,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )
        let video2 = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/b.mp4"),
            durationSeconds: 45.0,
            dimensions: CGSize(width: 1080, height: 1920),
            audioBitrate: 128_000,
            audioSampleRate: 48000,
            thumbnailData: nil
        )

        var project = CoreoProject(
            name: "Test Project",
            videos: [video1, video2],
            syncOffsets: [-2.0, 0.0]
        )
        project.audioSourceIndex = 1
        project.speedSegments = [
            SpeedSegment(
                id: UUID(),
                startTimeSeconds: 5.0,
                durationSeconds: 3.0,
                rate: 0.5,
                holdDurationSeconds: nil
            )
        ]
        project.annotations = [
            TimedAnnotation(
                id: UUID(),
                startTimeSeconds: 10.0,
                durationSeconds: 3.0,
                isPersistent: false,
                content: .text(TextAnnotation(
                    text: "Look here",
                    position: CGPoint(x: 0.5, y: 0.5),
                    fontSize: 24,
                    colorHex: "#FF3B30"
                )),
                createdAt: Date()
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CoreoProject.self, from: data)

        XCTAssertEqual(decoded.id, project.id)
        XCTAssertEqual(decoded.name, "Test Project")
        XCTAssertEqual(decoded.videos.count, 2)
        XCTAssertEqual(decoded.syncOffsets, [-2.0, 0.0])
        XCTAssertEqual(decoded.audioSourceIndex, 1)
        XCTAssertEqual(decoded.speedSegments.count, 1)
        XCTAssertEqual(decoded.speedSegments[0].rate, 0.5)
        XCTAssertEqual(decoded.annotations.count, 1)

        // Verify annotation content survived the round-trip
        if case .text(let textAnnotation) = decoded.annotations[0].content {
            XCTAssertEqual(textAnnotation.text, "Look here")
            XCTAssertEqual(textAnnotation.colorHex, "#FF3B30")
        } else {
            XCTFail("Expected text annotation content")
        }
    }

    // MARK: - Timeline Computation

    func testTimelineStartAndEnd() {
        let video1 = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/a.mp4"),
            durationSeconds: 30.0,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )
        let video2 = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/b.mp4"),
            durationSeconds: 45.0,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )

        let project = CoreoProject(
            name: "Timeline Test",
            videos: [video1, video2],
            syncOffsets: [-5.0, 0.0]
        )

        // Video 1: starts at -5, ends at -5+30 = 25
        // Video 2: starts at 0, ends at 0+45 = 45
        XCTAssertEqual(project.timelineStartSeconds, -5.0, accuracy: 0.001)
        XCTAssertEqual(project.timelineEndSeconds, 45.0, accuracy: 0.001)
        XCTAssertEqual(project.timelineDurationSeconds, 50.0, accuracy: 0.001)
    }

    func testOverlapComputation() {
        let video1 = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/a.mp4"),
            durationSeconds: 30.0,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )
        let video2 = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/b.mp4"),
            durationSeconds: 20.0,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )

        let project = CoreoProject(
            name: "Overlap Test",
            videos: [video1, video2],
            syncOffsets: [0.0, 5.0]
        )

        // Video 1: 0-30, Video 2: 5-25
        // Overlap starts at max(0, 5) = 5
        // Overlap ends at min(30, 25) = 25
        XCTAssertEqual(project.overlapStartSeconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(project.overlapEndSeconds, 25.0, accuracy: 0.001)
    }

    func testEmptyProjectTimeline() {
        let project = CoreoProject()

        XCTAssertEqual(project.timelineStartSeconds, 0)
        XCTAssertEqual(project.timelineEndSeconds, 0)
        XCTAssertEqual(project.timelineDurationSeconds, 0)
        XCTAssertEqual(project.overlapStartSeconds, 0)
        XCTAssertEqual(project.overlapEndSeconds, 0)
    }

    // MARK: - Save / Load

    func testSaveAndLoad() throws {
        let video = VideoAsset(
            id: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/save_test.mp4"),
            durationSeconds: 10.0,
            dimensions: CGSize(width: 1280, height: 720),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: nil
        )

        let original = CoreoProject(
            name: "Save Test",
            videos: [video],
            syncOffsets: [0.0]
        )

        try original.save()

        let loaded = CoreoProject.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, original.id)
        XCTAssertEqual(loaded?.name, "Save Test")
        XCTAssertEqual(loaded?.videos.count, 1)
        XCTAssertEqual(loaded?.videos[0].durationSeconds, 10.0, accuracy: 0.001)

        // Clean up
        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let fileURL = documentsDirectory.appendingPathComponent("coreo_project.json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testLoadReturnsNilWhenNoFileExists() {
        // Ensure there's no leftover file
        let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        let fileURL = documentsDirectory.appendingPathComponent("coreo_project.json")
        try? FileManager.default.removeItem(at: fileURL)

        let loaded = CoreoProject.load()
        XCTAssertNil(loaded)
    }
}
