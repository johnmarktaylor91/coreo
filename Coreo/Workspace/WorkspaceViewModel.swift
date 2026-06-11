// WorkspaceViewModel.swift
// Coreo
//
// Central view model for the workspace screen. Owns all AVPlayers, drives
// the unified timeline clock, and coordinates playback, seeking, rate
// changes, audio source switching, and annotation mode.

import AVFoundation
import Combine
import SwiftUI

/// The main brain of the workspace: manages synchronized multi-angle
/// video playback driven by a single authoritative timeline.
@MainActor
final class WorkspaceViewModel: ObservableObject {

    // MARK: - Project State

    /// The project being viewed/edited. Mutated for settings like audioSourceIndex.
    @Published var project: CoreoProject

    // MARK: - Playback State

    /// Whether all players are currently playing.
    @Published var isPlaying: Bool = false

    /// Current playhead position in timeline seconds.
    @Published var currentTimeSeconds: Double = 0.0

    /// Global playback rate applied to all players.
    @Published var playbackRate: Float = 1.0

    // MARK: - UI State

    /// True when the annotation drawing overlay is active.
    @Published var isAnnotationMode: Bool = false

    /// True when the edit tools panel is expanded.
    @Published var isEditToolsVisible: Bool = false

    /// True while an export operation is in progress.
    @Published var isExporting: Bool = false

    /// 0.0-1.0 progress of an active export.
    @Published var exportProgress: Double = 0.0

    /// URL of the last exported video, triggers the share sheet.
    @Published var exportedVideoURL: URL?

    /// True when the share sheet should be presented.
    @Published var showShareSheet: Bool = false

    /// Error message from a failed export, shown as an alert.
    @Published var exportError: String?

    /// True when the speed picker popover is shown.
    @Published var isSpeedPickerVisible: Bool = false

    /// The active export task, kept so it can be cancelled.
    private var exportTask: Task<Void, Never>?

    // MARK: - Players

    /// One AVPlayer per video, ordered to match `project.videos`.
    private(set) var players: [AVPlayer] = []

    /// Periodic time observer token on the reference player.
    private var timeObserver: Any?

    /// Index of the player that owns the time observer — must match
    /// the player used in `installTimeObserver` to avoid removing
    /// from the wrong player.
    private var timeObserverPlayerIndex: Int = 0

    /// Bag for Combine subscriptions (end-of-item notifications).
    private var cancellables = Set<AnyCancellable>()

    /// Background/foreground observation tokens.
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// Whether playback was active before the app went to background.
    private var wasPlayingBeforeBackground = false

    // MARK: - Constants

    /// Available playback rates for the speed picker.
    static let availableRates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

    // MARK: - Timeline Convenience

    /// Earliest point on the timeline (minimum sync offset).
    var timelineStart: Double { project.timelineStartSeconds }

    /// Latest point on the timeline (maximum video end).
    var timelineEnd: Double { project.timelineEndSeconds }

    /// Total span from earliest start to latest end.
    var timelineDuration: Double { project.timelineDurationSeconds }

    // MARK: - Init / Deinit

    /// Creates the view model, builds one AVPlayer per video, configures
    /// audio routing and sync offsets, and installs the periodic time observer.
    ///
    /// - Parameter project: The project to display in the workspace.
    init(project: CoreoProject) {
        self.project = project
        setupPlayers()
        installTimeObserver()
        observeEndOfPlayback()
        observeAppLifecycle()
    }

    // No deinit — @MainActor deinit cannot access isolated properties.
    // Cleanup is handled by tearDown() called from WorkspaceView.onDisappear.

    // MARK: - Playback Controls

    /// Toggles between playing and paused. Re-syncs all players on resume.
    func togglePlayback() {
        if isPlaying {
            pauseAll()
            currentSegmentRate = nil
        } else {
            // Re-sync before starting so every player is frame-accurate.
            currentSegmentRate = nil
            seekAll(to: currentTimeSeconds)
            playAll()
        }
        isPlaying.toggle()
    }

    /// Seeks all players to the given timeline position.
    ///
    /// - Parameter timelineSeconds: Desired playhead position in timeline coordinates.
    func seek(to timelineSeconds: Double) {
        let clamped = clampToTimeline(timelineSeconds)
        currentTimeSeconds = clamped

        for (index, player) in players.enumerated() {
            let cmTime = videoTime(forTimeline: clamped, videoIndex: index)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Sets the global playback rate and applies it to all currently-playing players.
    ///
    /// - Parameter rate: New rate (e.g., 0.5 for half speed).
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            for player in players {
                player.rate = rate
            }
        }
    }

    /// Cycles to the next available playback rate. Wraps around.
    func cyclePlaybackRate() {
        guard let currentIndex = Self.availableRates.firstIndex(of: playbackRate) else {
            // If the current rate isn't in the list, reset to 1x.
            setPlaybackRate(1.0)
            return
        }
        let nextIndex = (currentIndex + 1) % Self.availableRates.count
        setPlaybackRate(Self.availableRates[nextIndex])
    }

    // MARK: - Audio Source

    /// Switches which video's audio is heard during playback.
    ///
    /// - Parameter index: Index into `project.videos` for the desired audio source.
    func setAudioSource(index: Int) {
        guard index >= 0, index < players.count else { return }
        project.audioSourceIndex = index
        for (i, player) in players.enumerated() {
            player.isMuted = (i != index)
        }
    }

    // MARK: - Annotation Mode

    /// The currently selected annotation tool.
    @Published var selectedAnnotationTool: AnnotationTool = .pencil

    /// The currently selected annotation color hex string.
    @Published var selectedAnnotationColorHex: String = "#FF6B36"

    /// ID of the currently selected annotation (for editing/erasing).
    @Published var selectedAnnotationID: UUID?

    /// Enters annotation mode: pauses playback and shows the drawing overlay.
    func enterAnnotationMode(tool: AnnotationTool? = nil) {
        if let tool { selectedAnnotationTool = tool }
        isAnnotationMode = true
        if isPlaying {
            togglePlayback()
        }
    }

    /// Exits annotation mode. Does not auto-resume playback.
    func exitAnnotationMode() {
        isAnnotationMode = false
        selectedAnnotationID = nil
    }

    // MARK: - Annotation CRUD

    /// Adds a freehand drawing annotation at the current playhead.
    func addDrawingAnnotation(drawingData: Data) {
        let timeRange = TimedAnnotation.defaultTimeRange(
            at: currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: timeRange.start,
            durationSeconds: timeRange.duration,
            isPersistent: false,
            content: .drawing(DrawingAnnotation(drawingData: drawingData)),
            createdAt: Date()
        )
        project.annotations.append(annotation)
    }

    /// Adds a text annotation at the given normalized position.
    func addTextAnnotation(text: String, position: CGPoint) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let timeRange = TimedAnnotation.defaultTimeRange(
            at: currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: timeRange.start,
            durationSeconds: timeRange.duration,
            isPersistent: false,
            content: .text(TextAnnotation(
                text: text,
                position: position,
                fontSize: 16,
                colorHex: selectedAnnotationColorHex
            )),
            createdAt: Date()
        )
        project.annotations.append(annotation)
    }

    /// Adds an arrow annotation between two normalized points.
    func addArrowAnnotation(start: CGPoint, end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard sqrt(dx * dx + dy * dy) > 0.02 else { return } // Too short
        let timeRange = TimedAnnotation.defaultTimeRange(
            at: currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        let annotation = TimedAnnotation(
            id: UUID(),
            startTimeSeconds: timeRange.start,
            durationSeconds: timeRange.duration,
            isPersistent: false,
            content: .arrow(ArrowAnnotation(
                start: start,
                end: end,
                colorHex: selectedAnnotationColorHex,
                lineWidth: 3
            )),
            createdAt: Date()
        )
        project.annotations.append(annotation)
    }

    /// Deletes the annotation with the given ID.
    func deleteAnnotation(id: UUID) {
        project.annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
    }

    /// Updates a text annotation's position (normalized coordinates).
    func updateAnnotationPosition(id: UUID, position: CGPoint) {
        guard let idx = project.annotations.firstIndex(where: { $0.id == id }) else { return }
        if case .text(var text) = project.annotations[idx].content {
            text.position = position
            project.annotations[idx].content = .text(text)
        }
    }

    // MARK: - Speed Segments (Live Playback)

    /// Whether speed control editing is visible.
    @Published var isSpeedControlVisible: Bool = false

    // MARK: - Export Settings

    /// Selected export aspect ratio.
    @Published var exportAspectRatio: ExportAspectRatio = .landscape

    /// Export resolution based on selected aspect ratio.
    var exportResolution: CGSize {
        exportAspectRatio.resolution
    }

    // MARK: - Export

    /// Starts the export pipeline. Shows progress overlay, then share sheet on success.
    func startExport() {
        guard !isExporting else { return }
        if isPlaying { togglePlayback() }

        isExporting = true
        exportProgress = 0.0
        exportError = nil

        exportTask = Task {
            do {
                let url = try await ExportEngine.export(
                    project: project,
                    resolution: self.exportResolution,
                    progressHandler: { [weak self] progress in
                        self?.exportProgress = progress
                    }
                )
                Haptic.success()
                exportedVideoURL = url
                isExporting = false
                showShareSheet = true
            } catch is CancellationError {
                isExporting = false
            } catch let error as ExportError where error == .cancelled {
                isExporting = false
            } catch {
                Haptic.error()
                exportError = error.localizedDescription
                isExporting = false
            }
        }
    }

    /// Cancels an in-progress export.
    func cancelExport() {
        exportTask?.cancel()
        isExporting = false
    }

    /// Cleans up the exported temp file. Call after the share sheet is dismissed.
    func cleanUpExportedFile() {
        if let url = exportedVideoURL {
            try? FileManager.default.removeItem(at: url)
            exportedVideoURL = nil
        }
    }

    // MARK: - Video Availability

    /// Whether a video has content at the given timeline position.
    ///
    /// - Parameters:
    ///   - index: Video index.
    ///   - timelineSeconds: Position on the timeline.
    /// - Returns: True if the video's local time is within its duration.
    func isVideoActive(index: Int, at timelineSeconds: Double) -> Bool {
        guard index >= 0, index < project.videos.count,
              index < project.syncOffsets.count else {
            return false
        }
        let videoSeconds = timelineSeconds - project.syncOffsets[index]
        return videoSeconds >= 0 && videoSeconds <= project.videos[index].durationSeconds
    }

    /// Returns a human-readable label for an inactive video panel.
    ///
    /// - Parameters:
    ///   - index: Video index.
    ///   - timelineSeconds: Current playhead position.
    /// - Returns: A label like "Starts in 0:04" or "Ended", or nil if the video is active.
    func inactiveLabel(forIndex index: Int, at timelineSeconds: Double) -> String? {
        guard index >= 0, index < project.videos.count,
              index < project.syncOffsets.count else {
            return nil
        }
        let videoSeconds = timelineSeconds - project.syncOffsets[index]
        if videoSeconds < 0 {
            return "Starts in \(TimeFormatting.formatShort(-videoSeconds))"
        } else if videoSeconds > project.videos[index].durationSeconds {
            return "Ended"
        }
        return nil
    }

    // MARK: - Private — Player Setup

    /// Creates one AVPlayer per video, configures audio routing and initial seek.
    private func setupPlayers() {
        players = project.videos.map { video in
            let item = AVPlayerItem(url: video.localURL)
            item.preferredForwardBufferDuration = 5
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            return player
        }

        // Mute all except the designated audio source.
        let audioIdx = min(project.audioSourceIndex, players.count - 1)
        for (i, player) in players.enumerated() {
            player.isMuted = (i != audioIdx)
        }

        // Seek each player to its sync-offset position at the timeline start.
        let startTime = timelineStart
        for (index, player) in players.enumerated() {
            let cmTime = videoTime(forTimeline: startTime, videoIndex: index)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        currentTimeSeconds = startTime
    }

    // MARK: - Private — Time Observer

    /// Installs a periodic time observer on the reference player that drives
    /// `currentTimeSeconds` at ~30 Hz.
    private func installTimeObserver() {
        guard !players.isEmpty else { return }
        let refIndex = validReferenceIndex
        timeObserverPlayerIndex = refIndex
        let interval = CMTime(value: 1, timescale: 30)

        timeObserver = players[refIndex].addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                let refSeconds = CMTimeGetSeconds(cmTime)
                guard refSeconds.isFinite else { return }
                guard self.validReferenceIndex < self.project.syncOffsets.count else { return }
                let timelineTime = refSeconds + self.project.syncOffsets[self.validReferenceIndex]
                self.currentTimeSeconds = timelineTime
                self.applyLiveSpeedSegment(at: timelineTime)
            }
        }
    }

    // MARK: - Private — End-of-Playback Looping

    /// Observes when the reference player reaches its end and loops all
    /// players back to the timeline start.
    private func observeEndOfPlayback() {
        guard !players.isEmpty else { return }
        let refIndex = validReferenceIndex
        guard let item = players[refIndex].currentItem else { return }

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.seekAll(to: self.timelineStart)
                    if self.isPlaying {
                        self.playAll()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Private — App Lifecycle

    /// Pauses players when the app backgrounds and resumes on foreground.
    private func observeAppLifecycle() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wasPlayingBeforeBackground = self.isPlaying
                if self.isPlaying {
                    self.pauseAll()
                    self.isPlaying = false
                }
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wasPlayingBeforeBackground else { return }
                self.wasPlayingBeforeBackground = false
                self.seekAll(to: self.currentTimeSeconds)
                self.playAll()
                self.isPlaying = true
            }
        }
    }

    // MARK: - Private — Live Speed Segments

    /// The rate currently applied by a speed segment (to avoid re-applying every tick).
    private var currentSegmentRate: Float?

    /// Checks if the playhead is inside a speed segment and adjusts player rates.
    private func applyLiveSpeedSegment(at timelineSeconds: Double) {
        let speedMap = SpeedMap(segments: project.speedSegments)
        let segmentRate = speedMap.rate(at: timelineSeconds)

        // Only update if the rate actually changed.
        if segmentRate != currentSegmentRate {
            currentSegmentRate = segmentRate

            if segmentRate == 0 {
                // Hold/freeze: pause all players but keep isPlaying true.
                for player in players { player.pause() }
            } else {
                let effectiveRate = playbackRate * segmentRate
                for player in players { player.rate = effectiveRate }
            }
        }
    }

    // MARK: - Private — Helpers

    /// Converts a timeline position to a per-video CMTime, accounting for sync offset.
    private func videoTime(forTimeline timelineSeconds: Double, videoIndex: Int) -> CMTime {
        guard videoIndex >= 0, videoIndex < project.syncOffsets.count else {
            return .zero
        }
        let videoSeconds = timelineSeconds - project.syncOffsets[videoIndex]
        return CMTime(seconds: max(0, videoSeconds), preferredTimescale: 600)
    }

    /// Seeks all players to the given timeline position without changing play state.
    private func seekAll(to timelineSeconds: Double) {
        let clamped = clampToTimeline(timelineSeconds)
        for (index, player) in players.enumerated() {
            let cmTime = videoTime(forTimeline: clamped, videoIndex: index)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Starts playback on all players at the current rate.
    private func playAll() {
        for player in players {
            player.rate = playbackRate
        }
    }

    /// Pauses all players.
    private func pauseAll() {
        for player in players {
            player.pause()
        }
    }

    /// Clamps a timeline value to [timelineStart, timelineEnd].
    private func clampToTimeline(_ seconds: Double) -> Double {
        min(max(seconds, timelineStart), timelineEnd)
    }

    /// The reference video index, clamped to valid range.
    private var validReferenceIndex: Int {
        guard !players.isEmpty else { return 0 }
        return min(project.referenceVideoIndex, players.count - 1)
    }

    /// Pauses all players and removes the time observer.
    /// Called explicitly when the workspace is dismissed.
    func tearDown() {
        if let observer = timeObserver, timeObserverPlayerIndex < players.count {
            players[timeObserverPlayerIndex].removeTimeObserver(observer)
            timeObserver = nil
        }
        for player in players {
            player.pause()
        }
        cancellables.removeAll()
        exportTask?.cancel()
        if let bg = backgroundObserver {
            NotificationCenter.default.removeObserver(bg)
            backgroundObserver = nil
        }
        if let fg = foregroundObserver {
            NotificationCenter.default.removeObserver(fg)
            foregroundObserver = nil
        }
    }
}

private extension ExportError {
    static func == (lhs: ExportError, rhs: ExportError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled): return true
        default: return false
        }
    }
}
