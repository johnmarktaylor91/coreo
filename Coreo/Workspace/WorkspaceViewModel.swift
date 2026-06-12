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
    @Published var project: CoreoProject {
        didSet {
            rebuildPlaybackCaches()
            scheduleAutosave()
        }
    }

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

    /// True while workspace re-sync is running.
    @Published var isResyncing: Bool = false

    /// The active export task, kept so it can be cancelled.
    private var exportTask: Task<Void, Never>?

    /// The project store used for media URL resolution and autosave.
    private let projectStore: ProjectStore

    /// Debounced autosave task.
    private var autosaveTask: Task<Void, Never>?

    // MARK: - Players

    /// One AVPlayer per video, ordered to match `project.videos`.
    private(set) var players: [AVPlayer] = []

    /// Host-time-driven playback clock task.
    private var clockTask: Task<Void, Never>?

    /// Last timeline time processed by the clock tick.
    private var previousTickTimelineSeconds: Double?

    /// Last host time used by the clock tick integrator.
    private var previousTickHostSeconds: CFTimeInterval?

    /// Last host time at which drift correction ran.
    private var lastDriftCheckHostSeconds: CFTimeInterval = 0

    /// Current cached speed map, rebuilt when speed segments change.
    private var speedMap: SpeedMap

    /// Current cached time mapper, rebuilt when project timing changes.
    private var timeMapper: TimeMapper

    /// Pure hold crossing detector.
    private let holdCoordinator = HoldPlaybackCoordinator()

    /// Pending hold resume task.
    private var holdTask: Task<Void, Never>?

    /// Current live hold event, if playback is intentionally frozen.
    @Published private(set) var activeHoldEvent: HoldPlaybackCoordinator.HoldEvent?

    /// Latest coalesced seek task.
    private var seekTask: Task<Void, Never>?

    /// Monotonic generation used to discard stale seeks.
    private var seekGeneration: Int = 0

    /// Last player plan applied to detect activation window transitions.
    private var lastPlan: PlayerSyncPlan?

    /// Background/foreground observation tokens.
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// Audio interruption observation token.
    private var interruptionObserver: NSObjectProtocol?

    /// Audio route change observation token.
    private var routeChangeObserver: NSObjectProtocol?

    /// Whether playback was active before the app went to background.
    private var wasPlayingBeforeBackground = false

    // MARK: - Constants

    /// Available playback rates for the speed picker.
    static let availableRates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

    // MARK: - Timeline Convenience

    /// Earliest point on the timeline (minimum sync offset).
    var timelineStart: Double {
        project.timelineStartSeconds
    }

    /// Latest point on the timeline (maximum video end).
    var timelineEnd: Double {
        project.timelineEndSeconds
    }

    /// Total span from earliest start to latest end.
    var timelineDuration: Double {
        project.timelineDurationSeconds
    }

    /// Videos whose copied media files are missing.
    var missingVideos: [VideoAsset] {
        project.videos.filter { $0.mediaAvailability == .missing }
    }

    // MARK: - Init / Deinit

    /// Creates the view model, builds one AVPlayer per video, configures
    /// audio routing and sync offsets, and installs the periodic time observer.
    ///
    /// - Parameter project: The project to display in the workspace.
    init(project: CoreoProject, projectStore: ProjectStore = ProjectStore()) {
        self.project = project
        self.projectStore = projectStore
        speedMap = SpeedMap(segments: project.speedSegments)
        timeMapper = TimeMapper(project: project)
        currentTimeSeconds = project.timelineStartSeconds
        setupPlayers()
        configureAudioSession()
        observeAppLifecycle()
        observeAudioSession()
    }

    // No deinit — @MainActor deinit cannot access isolated properties.
    // Cleanup is handled by tearDown() called from WorkspaceView.onDisappear.

    // MARK: - Playback Controls

    /// Toggles between playing and paused. Re-syncs all players on resume.
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    /// Seeks all players to the given timeline position.
    ///
    /// - Parameter timelineSeconds: Desired playhead position in timeline coordinates.
    func seek(to timelineSeconds: Double) {
        seek(to: timelineSeconds, precise: true)
    }

    /// Seeks all players to the given timeline position with a precision mode.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Desired playhead position in timeline coordinates.
    ///   - precise: True for tolerance-zero settles; false for coalesced scrub seeks.
    func seek(to timelineSeconds: Double, precise: Bool) {
        let clamped = clampToTimeline(timelineSeconds)
        currentTimeSeconds = clamped
        cancelHold()
        resetClockAnchor(at: clamped)
        coalescedSeek(to: clamped, precise: precise, resumeAfterSeek: isPlaying)
    }

    /// Sets the global playback rate and applies it to all currently-playing players.
    ///
    /// - Parameter rate: New rate (e.g., 0.5 for half speed).
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            resetClockAnchor(at: currentTimeSeconds)
            applyPlan(at: currentTimeSeconds, forceSeek: false)
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
        for (playerIndex, player) in players.enumerated() {
            player.isMuted = (playerIndex != index)
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
        if case var .text(text) = project.annotations[idx].content {
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
                let resolution = await MainActor.run { self.exportResolution }
                let url = try await ExportEngine.export(
                    project: project,
                    resolution: resolution,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            self?.exportProgress = progress
                        }
                    }
                )
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    isExporting = false
                    exportTask = nil
                    return
                }
                Haptic.success()
                exportedVideoURL = url
                isExporting = false
                showShareSheet = true
                exportTask = nil
            } catch is CancellationError {
                isExporting = false
                exportTask = nil
            } catch let error as ExportError where error == .cancelled {
                isExporting = false
                exportTask = nil
            } catch {
                Haptic.error()
                exportError = error.localizedDescription
                isExporting = false
                exportTask = nil
            }
        }
    }

    /// Cancels an in-progress export.
    func cancelExport() {
        exportTask?.cancel()
        isExporting = false
        showShareSheet = false
    }

    /// Cleans up the exported temp file. Call after the share sheet is dismissed.
    func cleanUpExportedFile() {
        if let url = exportedVideoURL {
            try? FileManager.default.removeItem(at: url)
            exportedVideoURL = nil
        }
    }

    /// Removes a missing-media video from the project and rebuilds players.
    ///
    /// - Parameter id: Video identity to remove.
    func removeMissingVideo(id: UUID) {
        guard let index = project.index(forVideoID: id) else { return }
        let wasPlaying = isPlaying
        pausePlayback()
        projectStore.deleteMedia(for: project.videos[index], projectID: project.id)
        project.removeVideo(id: id)
        players.removeAll()
        setupPlayers()
        if wasPlaying, !players.isEmpty {
            startPlayback()
        } else {
            isPlaying = false
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
        guard index >= 0, index < project.videos.count else {
            return false
        }
        return timeMapper.isClipActive(atTimeline: timelineSeconds, clipID: project.videos[index].id)
    }

    /// Returns a human-readable label for an inactive video panel.
    ///
    /// - Parameters:
    ///   - index: Video index.
    ///   - timelineSeconds: Current playhead position.
    /// - Returns: A label like "Starts in 0:04" or "Ended", or nil if the video is active.
    func inactiveLabel(forIndex index: Int, at timelineSeconds: Double) -> String? {
        guard index >= 0, index < project.videos.count else {
            return nil
        }
        let clip = TimeMapper.Clip(video: project.videos[index])
        let localSeconds = timelineSeconds - clip.syncOffsetSeconds
        if localSeconds < clip.clipStartSeconds {
            return "Starts in \(TimeFormatting.formatShort(clip.clipStartSeconds - localSeconds))"
        } else if localSeconds > clip.clipEndSeconds {
            return "Ended"
        }
        return nil
    }

    /// Nudges a video's sync offset and immediately reapplies playback planning.
    ///
    /// - Parameters:
    ///   - index: Video display index.
    ///   - deltaSeconds: Offset delta to add.
    func nudgeSyncOffset(index: Int, deltaSeconds: Double) {
        guard project.videos.indices.contains(index) else { return }
        project.videos[index].syncOffsetSeconds += deltaSeconds
        resetClockAnchor(at: currentTimeSeconds)
        coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: isPlaying)
    }

    /// Re-runs audio sync from the workspace and updates per-video offsets/status.
    func resyncProject() {
        guard !isResyncing, project.videos.count >= 2 else { return }
        let wasPlaying = isPlaying
        if wasPlaying {
            pausePlayback()
        }
        isResyncing = true
        exportError = nil
        let inputs = project.videos.map {
            (url: projectStore.mediaURL(for: $0, projectID: project.id), audioBitrate: $0.audioBitrate)
        }

        Task {
            do {
                let output = try await AudioSyncEngine.sync(videos: inputs)
                await MainActor.run {
                    for result in output.results where project.videos.indices.contains(result.videoIndex) {
                        project.videos[result.videoIndex].syncOffsetSeconds = result.offsetSeconds
                        project.videos[result.videoIndex].syncStatus = result.status
                    }
                    project.referenceVideoIndex = output.referenceIndex
                    project.audioSourceIndex = output.audioSourceIndex
                    isResyncing = false
                    coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: wasPlaying)
                    if wasPlaying {
                        isPlaying = true
                        startClockLoop()
                    }
                }
            } catch {
                await MainActor.run {
                    isResyncing = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    /// Human-readable sync status for a video.
    ///
    /// - Parameter index: Video display index.
    /// - Returns: Compact status label.
    func syncStatusLabel(for index: Int) -> String {
        guard project.videos.indices.contains(index) else { return "Unknown" }
        switch project.videos[index].syncStatus {
        case .synced:
            return "Synced"
        case .noAudio:
            return "No audio"
        case .failed:
            return "Manual"
        }
    }

    // MARK: - Private — Player Setup

    /// Creates one AVPlayer per video, configures audio routing and initial seek.
    private func setupPlayers() {
        players = project.videos.map { video in
            let item = AVPlayerItem(url: projectStore.mediaURL(for: video, projectID: project.id))
            item.preferredForwardBufferDuration = 5
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            return player
        }

        // Mute all except the designated audio source.
        let audioIndex = min(project.audioSourceIndex, players.count - 1)
        for (playerIndex, player) in players.enumerated() {
            player.isMuted = (playerIndex != audioIndex)
        }

        // Seek each player to its sync-offset position at the timeline start.
        let startTime = timelineStart
        let plan = PlayerSyncPlan.make(timelineSeconds: startTime, mapper: timeMapper, rate: 0)
        for (index, player) in players.enumerated() where index < plan.states.count {
            let cmTime = PlayerSyncPlan.cmTime(for: plan.states[index])
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        currentTimeSeconds = startTime
    }

    // MARK: - Private — Master Clock

    /// Starts host-time-anchored playback from the current timeline position.
    private func startPlayback() {
        guard !players.isEmpty else { return }
        cancelHold()
        activateAudioSession()
        isPlaying = true
        resetClockAnchor(at: currentTimeSeconds)
        coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: true)
        startClockLoop()
    }

    /// Pauses playback and freezes the master timeline at the current position.
    private func pausePlayback() {
        cancelHold()
        isPlaying = false
        stopClockLoop()
        pauseAll()
        resetClockAnchor(at: currentTimeSeconds)
    }

    /// Starts the clock loop if it is not already running.
    private func startClockLoop() {
        guard clockTask == nil else { return }
        previousTickTimelineSeconds = currentTimeSeconds
        previousTickHostSeconds = CACurrentMediaTime()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_333_333)
                await MainActor.run {
                    self?.tickMasterClock()
                }
            }
        }
    }

    /// Stops the clock loop.
    private func stopClockLoop() {
        clockTask?.cancel()
        clockTask = nil
        previousTickHostSeconds = nil
    }

    /// Advances the unified timeline from host time and applies player state.
    private func tickMasterClock() {
        guard isPlaying, activeHoldEvent == nil else { return }
        let hostNow = CACurrentMediaTime()
        let previousHost = previousTickHostSeconds ?? hostNow
        let previousTimeline = previousTickTimelineSeconds ?? currentTimeSeconds
        let delta = max(0, hostNow - previousHost)
        let segmentRate = speedMap.rate(at: previousTimeline)
        let effectiveRate = playbackRate * segmentRate
        var nextTimeline = previousTimeline + delta * Double(max(effectiveRate, 0))

        if nextTimeline >= timelineEnd {
            nextTimeline = timelineStart
            coalescedSeek(to: nextTimeline, precise: true, resumeAfterSeek: true)
        }

        if let holdEvent = holdCoordinator.crossedHold(
            previousSeconds: previousTimeline,
            currentSeconds: nextTimeline,
            speedMap: speedMap,
            playbackRate: playbackRate
        ) {
            beginHold(holdEvent)
            previousTickHostSeconds = hostNow
            previousTickTimelineSeconds = holdEvent.holdTimelineSeconds
            return
        }

        currentTimeSeconds = nextTimeline
        previousTickHostSeconds = hostNow
        previousTickTimelineSeconds = nextTimeline
        applyPlan(at: nextTimeline, forceSeek: false)
        correctDriftIfNeeded(hostNow: hostNow, timelineSeconds: nextTimeline)
    }

    /// Resets the host-time anchor for the current master timeline.
    ///
    /// - Parameter timelineSeconds: Timeline time to anchor.
    private func resetClockAnchor(at timelineSeconds: Double) {
        let hostNow = CACurrentMediaTime()
        previousTickTimelineSeconds = timelineSeconds
        previousTickHostSeconds = hostNow
    }

    /// Begins a live hold and schedules playback resumption.
    ///
    /// - Parameter event: Hold event to apply.
    private func beginHold(_ event: HoldPlaybackCoordinator.HoldEvent) {
        activeHoldEvent = event
        currentTimeSeconds = event.holdTimelineSeconds
        resetClockAnchor(at: event.holdTimelineSeconds)
        pauseAll()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, event.wallDurationSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.resumeFromHold(event)
            }
        }
    }

    /// Resumes playback after a live hold if the event is still current.
    ///
    /// - Parameter event: Hold event that completed.
    private func resumeFromHold(_ event: HoldPlaybackCoordinator.HoldEvent) {
        guard activeHoldEvent == event else { return }
        activeHoldEvent = nil
        currentTimeSeconds = clampToTimeline(event.resumeTimelineSeconds)
        resetClockAnchor(at: currentTimeSeconds)
        if isPlaying {
            coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: true)
            startClockLoop()
        }
    }

    /// Cancels any live hold and clears its UI state.
    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        activeHoldEvent = nil
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
                saveImmediately()
                wasPlayingBeforeBackground = isPlaying
                if isPlaying {
                    pausePlayback()
                }
            }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, wasPlayingBeforeBackground else { return }
                wasPlayingBeforeBackground = false
                startPlayback()
            }
        }
    }

    /// Configures the audio category without activating the session.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Activates audio on first actual playback.
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Observes audio interruptions and route changes.
    private func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isPlaying else { return }
                resetClockAnchor(at: currentTimeSeconds)
                applyPlan(at: currentTimeSeconds, forceSeek: true)
            }
        }
    }

    /// Handles audio interruptions by pausing UI and player state together.
    ///
    /// - Parameter notification: Audio interruption notification.
    private func handleAudioInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            wasPlayingBeforeBackground = isPlaying
            if isPlaying {
                pausePlayback()
            }
        case .ended:
            if wasPlayingBeforeBackground {
                wasPlayingBeforeBackground = false
                startPlayback()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Private — Live Speed Segments

    /// Applies the current pure player plan to AVPlayers.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Timeline time to apply.
    ///   - forceSeek: Whether to force a seek before setting host-time rate.
    private func applyPlan(at timelineSeconds: Double, forceSeek: Bool) {
        let effectiveRate = playbackRate * speedMap.rate(at: timelineSeconds)
        let plan = PlayerSyncPlan.make(timelineSeconds: timelineSeconds, mapper: timeMapper, rate: effectiveRate)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())

        for (index, player) in players.enumerated() where index < plan.states.count {
            let state = plan.states[index]
            let previousState = lastPlan?.states.indices.contains(index) == true
                ? lastPlan?.states[index]
                : nil
            let cmTime = PlayerSyncPlan.cmTime(for: state)

            switch state {
            case let .active(_, rate):
                let wasInactive: Bool
                if case .inactive = previousState {
                    wasInactive = true
                } else {
                    wasInactive = false
                }
                if forceSeek || wasInactive {
                    player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] _ in
                        player?.setRate(rate, time: cmTime, atHostTime: hostTime)
                    }
                } else {
                    player.setRate(rate, time: cmTime, atHostTime: hostTime)
                }
            case .inactive:
                player.pause()
                if forceSeek || previousState != state {
                    player.seek(to: cmTime, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
                }
            }
        }

        lastPlan = plan
    }

    /// Corrects active-player drift at roughly one-second cadence.
    ///
    /// - Parameters:
    ///   - hostNow: Current host time.
    ///   - timelineSeconds: Current timeline time.
    private func correctDriftIfNeeded(hostNow: CFTimeInterval, timelineSeconds: Double) {
        guard hostNow - lastDriftCheckHostSeconds >= 1 else { return }
        lastDriftCheckHostSeconds = hostNow
        let frameTolerance = 1.0 / 30.0
        let plan = PlayerSyncPlan.make(
            timelineSeconds: timelineSeconds,
            mapper: timeMapper,
            rate: playbackRate * speedMap.rate(at: timelineSeconds)
        )

        for (index, player) in players.enumerated() where index < plan.states.count {
            guard case let .active(expectedSeconds, rate) = plan.states[index] else { continue }
            let actualSeconds = CMTimeGetSeconds(player.currentTime())
            guard actualSeconds.isFinite, abs(actualSeconds - expectedSeconds) > frameTolerance else { continue }
            let target = CMTime(seconds: expectedSeconds, preferredTimescale: 600)
            player.setRate(rate, time: target, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    // MARK: - Private — Helpers

    /// Pauses all players.
    private func pauseAll() {
        for player in players {
            player.pause()
        }
    }

    /// Coalesces seeks so only the latest request can resume playback.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Timeline time to seek to.
    ///   - precise: Whether to use tolerance-zero seeking.
    ///   - resumeAfterSeek: Whether playback should resume after the latest seek lands.
    private func coalescedSeek(to timelineSeconds: Double, precise: Bool, resumeAfterSeek: Bool) {
        seekGeneration += 1
        let generation = seekGeneration
        seekTask?.cancel()
        pauseAll()
        lastPlan = nil

        let clamped = clampToTimeline(timelineSeconds)
        let plan = PlayerSyncPlan.make(
            timelineSeconds: clamped,
            mapper: timeMapper,
            rate: playbackRate * speedMap.rate(at: clamped)
        )
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)

        seekTask = Task { [weak self] in
            let seekTargets: [(AVPlayer, CMTime)] = await MainActor.run {
                guard let self else { return [] }
                return self.players.enumerated().compactMap { index, player in
                    guard index < plan.states.count else { return nil }
                    return (player, PlayerSyncPlan.cmTime(for: plan.states[index]))
                }
            }

            for (player, target) in seekTargets {
                guard !Task.isCancelled else { return }
                await Self.seek(player: player, to: target, tolerance: tolerance)
            }

            await MainActor.run {
                guard let self, generation == self.seekGeneration, !Task.isCancelled else { return }
                self.currentTimeSeconds = clamped
                self.resetClockAnchor(at: clamped)
                if resumeAfterSeek, self.isPlaying {
                    self.applyPlan(at: clamped, forceSeek: false)
                    self.startClockLoop()
                } else {
                    self.applyPlan(at: clamped, forceSeek: false)
                    self.pauseAll()
                }
            }
        }
    }

    /// Awaits an AVPlayer seek completion.
    ///
    /// - Parameters:
    ///   - player: Player to seek.
    ///   - time: Target time.
    ///   - tolerance: Seek tolerance.
    private nonisolated static func seek(player: AVPlayer, to time: CMTime, tolerance: CMTime) async {
        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
                continuation.resume()
            }
        }
    }

    /// Rebuilds playback caches after project timing or speed changes.
    private func rebuildPlaybackCaches() {
        speedMap = SpeedMap(segments: project.speedSegments)
        timeMapper = TimeMapper(project: project)
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

    /// Schedules a debounced autosave after project mutations.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = project
        let store = projectStore
        autosaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try store.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// Saves the current project immediately.
    private func saveImmediately() {
        autosaveTask?.cancel()
        autosaveTask = nil
        try? projectStore.save(project)
    }

    /// Pauses all players and removes the time observer.
    /// Called explicitly when the workspace is dismissed.
    func tearDown() {
        stopClockLoop()
        cancelHold()
        seekTask?.cancel()
        for player in players {
            player.pause()
        }
        exportTask?.cancel()
        saveImmediately()
        autosaveTask?.cancel()
        if let backgroundToken = backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundToken)
            backgroundObserver = nil
        }
        if let foregroundToken = foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundToken)
            foregroundObserver = nil
        }
        if let interruption = interruptionObserver {
            NotificationCenter.default.removeObserver(interruption)
            interruptionObserver = nil
        }
        if let routeChange = routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChange)
            routeChangeObserver = nil
        }
    }
}

private extension ExportError {
    static func == (lhs: ExportError, rhs: ExportError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled): true
        default: false
        }
    }
}
