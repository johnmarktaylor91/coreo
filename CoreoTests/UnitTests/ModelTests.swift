// ModelTests.swift
// CoreoTests
//
// Unit tests for CoreoProject, VideoAsset, and ProjectStore persistence.

@testable import Coreo
import XCTest

final class ModelTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreoModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
    }

    // MARK: - VideoAsset Round-Trip

    func testVideoAssetJSONRoundTrip() throws {
        let original = makeVideo(
            filename: "test_video.mp4",
            duration: 125.5,
            offset: -2,
            status: .noAudio,
            autoCrop: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoAsset.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.relativePath, "media/test_video.mp4")
        XCTAssertEqual(decoded.originalFilename, "test_video.mp4")
        XCTAssertEqual(decoded.syncOffsetSeconds, -2, accuracy: 0.001)
        XCTAssertEqual(decoded.syncStatus, .noAudio)
        XCTAssertEqual(decoded.autoCropRect, original.autoCropRect)
        XCTAssertFalse(decoded.isMirrored)
        XCTAssertEqual(decoded.durationSeconds, original.durationSeconds, accuracy: 0.001)
    }

    func testVideoAssetDecodesLegacyPayloadWithoutMirrorFlag() throws {
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "relativePath": "media/legacy.mp4",
          "originalFilename": "legacy.mp4",
          "durationSeconds": 12,
          "dimensions": [1920, 1080],
          "audioBitrate": 128000,
          "audioSampleRate": 48000,
          "thumbnailData": null
        }
        """

        let decoded = try JSONDecoder().decode(VideoAsset.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(decoded.isMirrored)
        XCTAssertEqual(decoded.syncOffsetSeconds, 0)
        XCTAssertEqual(decoded.syncStatus, .synced)
    }

    func testVideoAssetFormattedDuration() {
        let asset = makeVideo(filename: "v.mp4", duration: 83.45)

        XCTAssertEqual(asset.formattedDuration, "1:23")
    }

    func testMediaURLResolvesRelativePath() {
        let asset = makeVideo(filename: "v.mp4", duration: 10)
        let root = tempRoot.appendingPathComponent("Project", isDirectory: true)

        XCTAssertEqual(asset.mediaURL(projectRoot: root), root.appendingPathComponent("media/v.mp4"))
    }

    // MARK: - CoreoProject Round-Trip

    func testCoreProjectJSONRoundTripIncludesSchemaVersionAndPerVideoState() throws {
        let video1 = makeVideo(filename: "a.mp4", duration: 30, offset: -2)
        let video2 = makeVideo(filename: "b.mp4", duration: 45, offset: 0)

        var project = CoreoProject(
            name: "Test Project",
            videos: [video1, video2],
            referenceVideoID: video2.id,
            audioSourceVideoID: video1.id
        )
        project.speedSegments = [
            SpeedSegment(
                id: UUID(),
                startTimeSeconds: 5,
                durationSeconds: 3,
                rate: 0.5,
                holdDurationSeconds: nil
            )
        ]
        project.annotations = [
            TimedAnnotation(
                id: UUID(),
                startTimeSeconds: 10,
                durationSeconds: 3,
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

        XCTAssertEqual(decoded.schemaVersion, CoreoProject.currentSchemaVersion)
        XCTAssertEqual(decoded.name, "Test Project")
        XCTAssertEqual(decoded.videos.map(\.syncOffsetSeconds), [-2, 0])
        XCTAssertEqual(decoded.referenceVideoID, video2.id)
        XCTAssertEqual(decoded.audioSourceVideoID, video1.id)
        XCTAssertEqual(decoded.speedSegments.count, 1)
        XCTAssertEqual(decoded.annotations.count, 1)
    }

    // MARK: - Timeline Computation

    func testTimelineStartAndEnd() {
        let video1 = makeVideo(filename: "a.mp4", duration: 30, offset: -5)
        let video2 = makeVideo(filename: "b.mp4", duration: 45, offset: 0)
        let project = CoreoProject(name: "Timeline Test", videos: [video1, video2])

        XCTAssertEqual(project.timelineStartSeconds, -5, accuracy: 0.001)
        XCTAssertEqual(project.timelineEndSeconds, 45, accuracy: 0.001)
        XCTAssertEqual(project.timelineDurationSeconds, 50, accuracy: 0.001)
    }

    func testOverlapComputation() {
        let video1 = makeVideo(filename: "a.mp4", duration: 30, offset: 0)
        let video2 = makeVideo(filename: "b.mp4", duration: 20, offset: 5)
        let project = CoreoProject(name: "Overlap Test", videos: [video1, video2])

        XCTAssertEqual(project.overlapStartSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(project.overlapEndSeconds, 25, accuracy: 0.001)
    }

    func testEmptyProjectTimeline() {
        let project = CoreoProject()

        XCTAssertEqual(project.timelineStartSeconds, 0)
        XCTAssertEqual(project.timelineEndSeconds, 0)
        XCTAssertEqual(project.timelineDurationSeconds, 0)
        XCTAssertEqual(project.overlapStartSeconds, 0)
        XCTAssertEqual(project.overlapEndSeconds, 0)
    }

    // MARK: - ProjectStore

    func testSaveAndLoadMostRecentProject() throws {
        let store = ProjectStore(projectsRoot: tempRoot)
        let project = CoreoProject(
            name: "Save Test",
            videos: [makeVideo(filename: "save_test.mp4", duration: 10)]
        )
        let projectDirectory = store.projectDirectory(for: project.id)
        let mediaDirectory = projectDirectory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: mediaDirectory.appendingPathComponent("save_test.mp4").path,
            contents: Data([1])
        )

        try store.save(project)

        let loaded = try XCTUnwrap(store.loadMostRecentProject())
        XCTAssertEqual(loaded.project.id, project.id)
        XCTAssertEqual(loaded.project.name, "Save Test")
        XCTAssertEqual(loaded.project.videos[0].mediaAvailability, .available)
    }

    func testWrongOrMissingSchemaVersionIsRenamedAside() throws {
        let store = ProjectStore(projectsRoot: tempRoot)
        let directory = store.projectDirectory(for: UUID())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectURL = directory.appendingPathComponent("project.json")
        try Data(#"{"name":"Old Project"}"#.utf8).write(to: projectURL)

        XCTAssertNil(store.loadProject(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
        let staleFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("project.stale-") }
        XCTAssertEqual(staleFiles.count, 1)
    }

    func testMissingMediaIsMarkedOnLoad() throws {
        let store = ProjectStore(projectsRoot: tempRoot)
        let project = CoreoProject(
            name: "Missing",
            videos: [makeVideo(filename: "missing.mp4", duration: 10)]
        )
        try store.save(project)

        let loaded = try XCTUnwrap(store.loadMostRecentProject())
        XCTAssertEqual(loaded.project.videos[0].mediaAvailability, .missing)
    }

    func testAtomicSaveLeavesExistingProjectOnSimulatedFailure() throws {
        let store = ProjectStore(projectsRoot: tempRoot)
        var project = CoreoProject(name: "Original", videos: [makeVideo(filename: "a.mp4", duration: 10)])
        try store.save(project)
        project.name = "Mutated"

        let encodedProject = try JSONEncoder().encode(project)
        XCTAssertThrowsError(try store.save(
            project,
            encodedData: encodedProject,
            simulateFailureAfterTemporaryWrite: true
        ))

        let loaded = try XCTUnwrap(store.loadMostRecentProject())
        XCTAssertEqual(loaded.project.name, "Original")
    }

    func testRemoveMissingMediaKeepsAvailableVideos() {
        let store = ProjectStore(projectsRoot: tempRoot)
        let available = makeVideo(filename: "available.mp4", duration: 10)
        var missing = makeVideo(filename: "missing.mp4", duration: 10)
        missing.mediaAvailability = .missing
        var project = CoreoProject(name: "Recovery", videos: [available, missing])

        let removed = store.removeMissingMedia(from: &project, projectID: project.id)

        XCTAssertEqual(removed.map(\.id), [missing.id])
        XCTAssertEqual(project.videos.map(\.id), [available.id])
    }

    func testReplacementDurationToleranceDecision() {
        XCTAssertFalse(MediaReplacementPolicy.requiresDurationWarning(
            originalDuration: 10,
            replacementDuration: 10.25
        ))
        XCTAssertTrue(MediaReplacementPolicy.requiresDurationWarning(
            originalDuration: 10,
            replacementDuration: 10.251
        ))
    }

    func testRepickedAssetKeepsUUIDAndOffsetsAfterSaveLoad() throws {
        let store = ProjectStore(projectsRoot: tempRoot)
        let originalID = UUID()
        let original = makeVideo(filename: "missing.mp4", duration: 10, offset: 1.25, id: originalID)
        let replacementMetadata = makeVideo(filename: "replacement.mp4", duration: 10.1, offset: -9)
        let recovered = original.replacingMedia(with: replacementMetadata)
        let project = CoreoProject(
            name: "Recovered",
            videos: [recovered],
            referenceVideoID: recovered.id,
            audioSourceVideoID: recovered.id
        )
        let mediaDirectory = store.mediaDirectory(for: project.id)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: mediaDirectory.appendingPathComponent("replacement.mp4").path,
            contents: Data([1])
        )

        try store.save(project)

        let loaded = try XCTUnwrap(store.loadMostRecentProject())
        let video = try XCTUnwrap(loaded.project.videos.first)
        XCTAssertEqual(video.id, originalID)
        XCTAssertEqual(video.syncOffsetSeconds, 1.25, accuracy: 0.0001)
        XCTAssertEqual(video.relativePath, "media/replacement.mp4")
        XCTAssertEqual(video.mediaAvailability, .available)
        XCTAssertEqual(
            store.mediaURL(for: video, projectID: loaded.project.id),
            store.projectDirectory(for: loaded.project.id).appendingPathComponent("media/replacement.mp4")
        )
    }

    // MARK: - Helpers

    private func makeVideo(
        filename: String,
        duration: Double,
        offset: Double = 0,
        status: SyncStatus = .synced,
        autoCrop: CGRect? = nil,
        id: UUID = UUID()
    ) -> VideoAsset {
        VideoAsset(
            id: id,
            relativePath: "media/\(filename)",
            originalFilename: filename,
            durationSeconds: duration,
            dimensions: CGSize(width: 1920, height: 1080),
            audioBitrate: 128_000,
            audioSampleRate: 44100,
            thumbnailData: Data([0x01, 0x02]),
            syncOffsetSeconds: offset,
            syncStatus: status,
            autoCropRect: autoCrop
        )
    }
}
