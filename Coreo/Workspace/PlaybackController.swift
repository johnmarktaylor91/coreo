// PlaybackController.swift
// Coreo
//
// Observable playback state and AVPlayer coordination for the workspace.

import AVFoundation
import Observation
import SwiftUI

/// Coordinates synchronized multi-angle playback from one timeline clock.
@MainActor
@Observable
final class PlaybackController {
    /// Whether all players are currently playing.
    var isPlaying: Bool = false

    /// Current playhead position in timeline seconds.
    var currentTimeSeconds: Double = 0.0

    /// Global playback rate applied to all players.
    var playbackRate: Float = 1.0

    /// True when the speed picker popover is shown.
    var isSpeedPickerVisible: Bool = false

    /// Session-only A-B loop state.
    private(set) var loopState: ABLoopState = .cleared

    /// Current live hold event, if playback is intentionally frozen.
    private(set) var activeHoldEvent: HoldPlaybackCoordinator.HoldEvent?

    /// One AVPlayer per video, ordered to match the project videos.
    private(set) var players: [AVPlayer] = []

    /// Available playback rates for the speed picker.
    static let availableRates: [Float] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

    /// Current project snapshot used for playback math.
    private var project: CoreoProject

    /// The project store used for media URL resolution.
    private let projectStore: ProjectStore

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

    /// Pure A-B loop policy.
    private var loopCoordinator = LoopPlaybackCoordinator()

    /// Pending hold resume task.
    private var holdTask: Task<Void, Never>?

    /// Latest coalesced seek task.
    private var seekTask: Task<Void, Never>?

    /// Monotonic generation used to discard stale seeks.
    private var seekGeneration: Int = 0

    /// Last player plan applied to detect activation window transitions.
    private var lastPlan: PlayerSyncPlan?

    /// Audio route change observation token.
    private var routeChangeObserver: NSObjectProtocol?

    /// Callback used to report playback/audio errors.
    private let errorHandler: @MainActor (String?) -> Void

    /// Creates a playback controller for the given project.
    ///
    /// - Parameters:
    ///   - project: Project snapshot to play.
    ///   - projectStore: Store used to resolve media URLs.
    ///   - errorHandler: Callback for surfacing playback/audio errors.
    init(
        project: CoreoProject,
        projectStore: ProjectStore,
        errorHandler: @escaping @MainActor (String?) -> Void
    ) {
        self.project = project
        self.projectStore = projectStore
        self.errorHandler = errorHandler
        speedMap = SpeedMap(segments: project.speedSegments)
        timeMapper = TimeMapper(project: project)
        currentTimeSeconds = project.timelineStartSeconds
        setupPlayers()
        configureAudioSession()
        observeAudioSession()
    }

    /// Replaces the project snapshot and rebuilds playback caches.
    ///
    /// - Parameter project: Updated project state.
    func updateProject(_ project: CoreoProject) {
        self.project = project
        let didClearLoop = loopCoordinator.clearIfOutOfBounds(durationEndSeconds: project.timelineEndSeconds)
        loopState = loopCoordinator.state
        if didClearLoop {
            Haptic.light()
        }
        rebuildPlaybackCaches()
    }

    /// Rebuilds AVPlayers for the current project.
    func rebuildPlayers() {
        players.removeAll()
        setupPlayers()
    }

    /// Toggles between playing and paused. Re-syncs all players on resume.
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    /// Pauses playback if it is currently active.
    func pauseIfNeeded() {
        if isPlaying {
            pausePlayback()
        }
    }

    /// Toggles playback immediately, without any count-in policy.
    func togglePlaybackImmediately() {
        togglePlayback()
    }

    /// Starts playback if players are available.
    func resumePlayback() {
        startPlayback()
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

    /// Reapplies the current seek and optionally resumes playback afterward.
    ///
    /// - Parameter resumeAfterSeek: Whether playback should resume after seeking.
    func settleCurrentSeek(resumeAfterSeek: Bool) {
        resetClockAnchor(at: currentTimeSeconds)
        coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: resumeAfterSeek)
        if resumeAfterSeek {
            isPlaying = true
            startClockLoop()
        }
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
            setPlaybackRate(1.0)
            return
        }
        let nextIndex = (currentIndex + 1) % Self.availableRates.count
        setPlaybackRate(Self.availableRates[nextIndex])
    }

    /// Applies audio muting for the selected source.
    ///
    /// - Parameter index: Index into the current player list.
    func setAudioSource(index: Int) {
        guard index >= 0, index < players.count else { return }
        for (playerIndex, player) in players.enumerated() {
            player.isMuted = (playerIndex != index)
        }
    }

    /// Applies the current unmuted angle set to players.
    ///
    /// - Parameter videoIDs: Video IDs whose panel audio should be audible.
    func setUnmutedVideoIDs(_ videoIDs: Set<UUID>) {
        for (index, player) in players.enumerated() where project.videos.indices.contains(index) {
            player.isMuted = !videoIDs.contains(project.videos[index].id)
        }
    }

    /// Moves the playhead by a fixed number of frames using a precise settle seek.
    ///
    /// - Parameters:
    ///   - frames: Number of frames to step, negative for backward.
    ///   - framesPerSecond: Timeline frame rate used for stepping.
    func stepFrames(_ frames: Int, framesPerSecond: Double = 30) {
        let steppedTime = Self.steppedTimelineTime(
            currentSeconds: currentTimeSeconds,
            frames: frames,
            framesPerSecond: framesPerSecond,
            timelineStart: project.timelineStartSeconds,
            timelineEnd: project.timelineEndSeconds
        )
        seek(to: steppedTime, precise: true)
    }

    /// Handles one A-B loop control activation at the current playhead.
    ///
    /// - Returns: Transition result for haptics and accessibility state.
    func activateLoopControl() -> ABLoopActivationResult {
        let result = loopCoordinator.activate(at: currentTimeSeconds)
        loopState = loopCoordinator.state
        return result
    }

    /// Active loop region if both points have been set.
    var activeLoopRegion: LoopRegion? {
        if case let .active(region) = loopState {
            return region
        }
        return nil
    }

    /// Computes frame-step target time clamped to the timeline.
    ///
    /// - Parameters:
    ///   - currentSeconds: Current timeline time.
    ///   - frames: Frame delta, negative to step backward.
    ///   - framesPerSecond: Frame rate used for stepping.
    ///   - timelineStart: Earliest timeline time.
    ///   - timelineEnd: Latest timeline time.
    /// - Returns: Clamped target time.
    nonisolated static func steppedTimelineTime(
        currentSeconds: Double,
        frames: Int,
        framesPerSecond: Double,
        timelineStart: Double,
        timelineEnd: Double
    ) -> Double {
        guard framesPerSecond > 0 else { return currentSeconds }
        let deltaSeconds = Double(frames) / framesPerSecond
        return min(max(currentSeconds + deltaSeconds, timelineStart), timelineEnd)
    }

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

    /// Reapplies playback planning after project timing changes.
    func seekAfterProjectTimingChange() {
        resetClockAnchor(at: currentTimeSeconds)
        coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: isPlaying)
    }

    /// Tears down playback tasks, observers, and players.
    func tearDown() {
        stopClockLoop()
        cancelHold()
        seekTask?.cancel()
        loopCoordinator.clear()
        loopState = loopCoordinator.state
        for player in players {
            player.pause()
        }
        if let routeChange = routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChange)
            routeChangeObserver = nil
        }
    }
}

// MARK: - Private Setup

private extension PlaybackController {
    /// Creates one AVPlayer per video, configures audio routing and initial seek.
    func setupPlayers() {
        players = project.videos.map { video in
            let item = AVPlayerItem(url: projectStore.mediaURL(for: video, projectID: project.id))
            item.preferredForwardBufferDuration = 5
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            return player
        }

        let audioIndex = min(project.audioSourceIndex, players.count - 1)
        for (playerIndex, player) in players.enumerated() {
            player.isMuted = (playerIndex != audioIndex)
        }

        let startTime = project.timelineStartSeconds
        let plan = PlayerSyncPlan.make(timelineSeconds: startTime, mapper: timeMapper, rate: 0)
        for (index, player) in players.enumerated() where index < plan.states.count {
            let cmTime = PlayerSyncPlan.cmTime(for: plan.states[index])
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        currentTimeSeconds = startTime
    }

    /// Configures the audio category without activating the session.
    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            errorHandler(error.localizedDescription)
        }
    }

    /// Activates audio on first actual playback.
    func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorHandler(error.localizedDescription)
        }
    }

    /// Observes audio route changes.
    func observeAudioSession() {
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
}

// MARK: - Private Clock

private extension PlaybackController {
    /// Starts host-time-anchored playback from the current timeline position.
    func startPlayback() {
        guard !players.isEmpty else { return }
        cancelHold()
        activateAudioSession()
        isPlaying = true
        resetClockAnchor(at: currentTimeSeconds)
        coalescedSeek(to: currentTimeSeconds, precise: true, resumeAfterSeek: true)
        startClockLoop()
    }

    /// Pauses playback and freezes the master timeline at the current position.
    func pausePlayback() {
        cancelHold()
        isPlaying = false
        stopClockLoop()
        pauseAll()
        resetClockAnchor(at: currentTimeSeconds)
    }

    /// Starts the clock loop if it is not already running.
    func startClockLoop() {
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
    func stopClockLoop() {
        clockTask?.cancel()
        clockTask = nil
        previousTickHostSeconds = nil
    }

    /// Advances the unified timeline from host time and applies player state.
    func tickMasterClock() {
        guard isPlaying, activeHoldEvent == nil else { return }
        let hostNow = CACurrentMediaTime()
        let previousHost = previousTickHostSeconds ?? hostNow
        let previousTimeline = previousTickTimelineSeconds ?? currentTimeSeconds
        let delta = max(0, hostNow - previousHost)
        let segmentRate = speedMap.rate(at: previousTimeline)
        let effectiveRate = playbackRate * segmentRate
        var nextTimeline = previousTimeline + delta * Double(max(effectiveRate, 0))

        if let loopTarget = loopCoordinator.loopSeekTarget(
            previousSeconds: previousTimeline,
            currentSeconds: nextTimeline,
            isPlaying: isPlaying
        ) {
            currentTimeSeconds = loopTarget
            resetClockAnchor(at: loopTarget)
            previousTickHostSeconds = hostNow
            previousTickTimelineSeconds = loopTarget
            coalescedSeek(to: loopTarget, precise: true, resumeAfterSeek: true)
            return
        }

        if nextTimeline >= project.timelineEndSeconds {
            nextTimeline = project.timelineStartSeconds
            coalescedSeek(to: nextTimeline, precise: true, resumeAfterSeek: true)
            return
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
    func resetClockAnchor(at timelineSeconds: Double) {
        let hostNow = CACurrentMediaTime()
        previousTickTimelineSeconds = timelineSeconds
        previousTickHostSeconds = hostNow
    }

    /// Begins a live hold and schedules playback resumption.
    ///
    /// - Parameter event: Hold event to apply.
    func beginHold(_ event: HoldPlaybackCoordinator.HoldEvent) {
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
    func resumeFromHold(_ event: HoldPlaybackCoordinator.HoldEvent) {
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
    func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        activeHoldEvent = nil
    }
}

// MARK: - Private Player Planning

private extension PlaybackController {
    /// Applies the current pure player plan to AVPlayers.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Timeline time to apply.
    ///   - forceSeek: Whether to force a seek before setting host-time rate.
    func applyPlan(at timelineSeconds: Double, forceSeek: Bool) {
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
                let wasInactive = if case .inactive = previousState {
                    true
                } else {
                    false
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
    func correctDriftIfNeeded(hostNow: CFTimeInterval, timelineSeconds: Double) {
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

    /// Pauses all players.
    func pauseAll() {
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
    func coalescedSeek(to timelineSeconds: Double, precise: Bool, resumeAfterSeek: Bool) {
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
}

// MARK: - Private Helpers

private extension PlaybackController {
    /// Rebuilds playback caches after project timing or speed changes.
    func rebuildPlaybackCaches() {
        speedMap = SpeedMap(segments: project.speedSegments)
        timeMapper = TimeMapper(project: project)
    }

    /// Clamps a timeline value to the project timeline.
    ///
    /// - Parameter seconds: Timeline value to clamp.
    /// - Returns: Clamped timeline value.
    func clampToTimeline(_ seconds: Double) -> Double {
        min(max(seconds, project.timelineStartSeconds), project.timelineEndSeconds)
    }
}
