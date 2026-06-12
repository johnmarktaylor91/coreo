// WorkspaceViewModel.swift
// Coreo
//
// Slim observable facade for workspace state. Owns project-level data and
// composes focused observable controllers for playback, annotations, and export.

import AVFoundation
import Observation
import SwiftUI
import UIKit

/// The workspace composition model that owns project state and focused controllers.
@MainActor
@Observable
final class WorkspaceViewModel {
    /// The project being viewed/edited. Mutated for settings like audioSourceIndex.
    var project: CoreoProject {
        didSet {
            syncChildrenFromProject()
            layoutCache.invalidate()
            scheduleAutosave()
        }
    }

    /// Playback state and AVPlayer coordination.
    let playback: PlaybackController

    /// Annotation collection and selection state.
    let annotations: AnnotationStore

    /// Export progress, cancellation, and share state.
    let export: ExportCoordinator

    /// Count-in preference and transient state.
    let countIn: CountInController

    /// True when the annotation drawing overlay is active.
    var isAnnotationMode: Bool = false

    /// True when the edit tools panel is expanded.
    var isEditToolsVisible: Bool = false

    /// True while workspace re-sync is running.
    var isResyncing: Bool = false

    /// Whether speed control editing is visible.
    var isSpeedControlVisible: Bool = false

    /// Video IDs currently allowed to play audio in preview.
    var unmutedVideoIDs: Set<UUID>

    /// Cached interactive scrub snap landmarks.
    private(set) var scrubSnapTargets: ScrubSnapTargets

    /// The project store used for media URL resolution and autosave.
    private let projectStore: ProjectStore

    /// Memoized layout calculation cache.
    private let layoutCache = LayoutCache()

    /// Debounced autosave task.
    private var autosaveTask: Task<Void, Never>?

    /// Background/foreground observation tokens.
    private var backgroundObserver: NSObjectProtocol?

    /// Foreground observation token.
    private var foregroundObserver: NSObjectProtocol?

    /// Audio interruption observation token.
    private var interruptionObserver: NSObjectProtocol?

    /// Whether playback was active before the app went to background.
    private var wasPlayingBeforeBackground = false

    /// Whether playback was active before entering annotation mode.
    private var wasPlayingBeforeAnnotationMode = false

    /// Earliest point on the timeline.
    var timelineStart: Double {
        project.timelineStartSeconds
    }

    /// Latest point on the timeline.
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

    /// Creates the workspace model and its focused controllers.
    ///
    /// - Parameters:
    ///   - project: The project to display in the workspace.
    ///   - projectStore: Store used for media resolution and autosave.
    init(project: CoreoProject, projectStore: ProjectStore = ProjectStore()) {
        self.project = project
        self.projectStore = projectStore
        annotations = AnnotationStore(annotations: project.annotations)
        export = ExportCoordinator()
        countIn = CountInController()
        unmutedVideoIDs = Set(project.audioSourceVideoID.map { [$0] } ?? [])
        scrubSnapTargets = ScrubSnapTargets.build(
            annotations: project.annotations,
            speedSegments: project.speedSegments,
            timelineStart: project.timelineStartSeconds,
            timelineEnd: project.timelineEndSeconds
        )
        playback = PlaybackController(
            project: project,
            projectStore: projectStore,
            errorHandler: { [export] message in
                export.exportError = message
            }
        )
        observeAppLifecycle()
        observeAudioSession()
    }

    /// Returns cached panel rectangles for the current project and container size.
    ///
    /// - Parameter containerSize: Available grid container size.
    /// - Returns: Panel rectangles in container coordinates.
    func panelRects(containerSize: CGSize) -> [CGRect] {
        layoutCache.panelRects(project: project, containerSize: containerSize)
    }

    /// Toggles between playing and paused.
    func togglePlayback() {
        if countIn.isActive {
            countIn.cancel()
            return
        }
        if playback.isPlaying {
            playback.togglePlaybackImmediately()
        } else if countIn.isEnabled {
            countIn.start(
                onCount: { _ in Haptic.tick() },
                onComplete: { [weak self] in
                    self?.playback.resumePlayback()
                }
            )
        } else {
            playback.togglePlaybackImmediately()
        }
    }

    /// Toggles playback immediately for programmatic resume paths.
    func togglePlaybackImmediately() {
        countIn.cancel()
        playback.togglePlaybackImmediately()
    }

    /// Cancels any active count-in without starting playback.
    func cancelCountIn() {
        countIn.cancel()
    }

    /// Seeks all players to the given timeline position.
    ///
    /// - Parameter timelineSeconds: Desired playhead position in timeline coordinates.
    func seek(to timelineSeconds: Double) {
        playback.seek(to: timelineSeconds)
    }

    /// Seeks all players to the given timeline position with a precision mode.
    ///
    /// - Parameters:
    ///   - timelineSeconds: Desired playhead position in timeline coordinates.
    ///   - precise: True for tolerance-zero settles; false for coalesced scrub seeks.
    func seek(to timelineSeconds: Double, precise: Bool) {
        countIn.cancel()
        playback.seek(to: timelineSeconds, precise: precise)
    }

    /// Handles the A-B loop control and returns its transition result.
    ///
    /// - Returns: Loop transition result.
    func activateLoopControl() -> ABLoopActivationResult {
        playback.activateLoopControl()
    }

    /// Switches which video's audio is heard during playback.
    ///
    /// - Parameter index: Index into `project.videos` for the desired audio source.
    func setAudioSource(index: Int) {
        guard index >= 0, index < playback.players.count else { return }
        project.audioSourceIndex = index
        unmutedVideoIDs = [project.videos[index].id]
        playback.setAudioSource(index: index)
    }

    /// Toggles whether one panel's audio is muted in preview.
    ///
    /// - Parameter index: Video display index.
    func togglePanelMute(index: Int) {
        guard project.videos.indices.contains(index) else { return }
        let id = project.videos[index].id
        if unmutedVideoIDs.contains(id) {
            unmutedVideoIDs.remove(id)
        } else {
            unmutedVideoIDs.insert(id)
        }
        playback.setUnmutedVideoIDs(unmutedVideoIDs)
    }

    /// Returns whether a panel is currently muted.
    ///
    /// - Parameter index: Video display index.
    /// - Returns: True when the panel's audio is muted.
    func isPanelMuted(index: Int) -> Bool {
        guard project.videos.indices.contains(index) else { return true }
        return !unmutedVideoIDs.contains(project.videos[index].id)
    }

    /// Toggles preview mirror mode for a panel and persists it on the video asset.
    ///
    /// - Parameter index: Video display index.
    func toggleMirror(index: Int) {
        guard project.videos.indices.contains(index) else { return }
        project.videos[index].isMirrored.toggle()
    }

    /// Steps the master playhead by one frame.
    ///
    /// - Parameter direction: -1 for backward, +1 for forward.
    func stepFrame(direction: Int) {
        countIn.cancel()
        playback.stepFrames(direction < 0 ? -1 : 1)
    }

    /// Enters annotation mode: pauses playback and shows the drawing overlay.
    ///
    /// - Parameter tool: Optional tool to select before entering.
    func enterAnnotationMode(tool: AnnotationTool? = nil) {
        if let tool {
            annotations.selectedAnnotationTool = tool
        }
        if !isAnnotationMode {
            wasPlayingBeforeAnnotationMode = playback.isPlaying
        }
        isAnnotationMode = true
        playback.pauseIfNeeded()
    }

    /// Exits annotation mode and resumes playback if annotation entry paused it.
    func exitAnnotationMode() {
        isAnnotationMode = false
        annotations.clearSelection()
        if wasPlayingBeforeAnnotationMode {
            wasPlayingBeforeAnnotationMode = false
            playback.resumePlayback()
        }
    }

    /// Adds a freehand drawing annotation at the current playhead.
    ///
    /// - Parameter drawingData: PencilKit drawing data.
    func addDrawingAnnotation(drawingData: Data, canvasSize: CGSize) {
        annotations.addDrawingAnnotation(
            drawingData: drawingData,
            canvasSize: canvasSize,
            currentTimeSeconds: playback.currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        syncProjectAnnotationsFromStore()
    }

    /// Adds a text annotation at the given normalized position.
    ///
    /// - Parameters:
    ///   - text: Text to render.
    ///   - position: Normalized annotation position.
    func addTextAnnotation(text: String, position: CGPoint, canvasSize: CGSize) {
        annotations.addTextAnnotation(
            text: text,
            position: position,
            canvasSize: canvasSize,
            currentTimeSeconds: playback.currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        syncProjectAnnotationsFromStore()
    }

    /// Adds an arrow annotation between two normalized points.
    ///
    /// - Parameters:
    ///   - start: Normalized start point.
    ///   - end: Normalized end point.
    func addArrowAnnotation(start: CGPoint, end: CGPoint, canvasSize: CGSize) {
        annotations.addArrowAnnotation(
            start: start,
            end: end,
            canvasSize: canvasSize,
            currentTimeSeconds: playback.currentTimeSeconds,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd
        )
        syncProjectAnnotationsFromStore()
    }

    /// Deletes the annotation with the given ID.
    ///
    /// - Parameter id: Annotation identity.
    func deleteAnnotation(id: UUID) {
        annotations.deleteAnnotation(id: id)
        syncProjectAnnotationsFromStore()
    }

    /// Updates a text annotation's position.
    ///
    /// - Parameters:
    ///   - id: Annotation identity.
    ///   - position: Normalized position.
    func updateAnnotationPosition(id: UUID, position: CGPoint) {
        annotations.updateAnnotationPosition(id: id, position: position)
        syncProjectAnnotationsFromStore()
    }

    /// Updates an annotation's visible timing window.
    ///
    /// - Parameters:
    ///   - id: Annotation identity.
    ///   - startTimeSeconds: New start time in timeline seconds.
    ///   - durationSeconds: New visible duration in timeline seconds.
    ///   - isPersistent: Whether the annotation should be shown for the full timeline.
    func updateAnnotationTiming(
        id: UUID,
        startTimeSeconds: Double,
        durationSeconds: Double,
        isPersistent: Bool
    ) {
        annotations.updateAnnotationTiming(
            id: id,
            startTimeSeconds: startTimeSeconds,
            durationSeconds: durationSeconds,
            isPersistent: isPersistent
        )
        syncProjectAnnotationsFromStore()
    }

    /// Starts the export pipeline.
    func startExport() {
        export.startExport(project: project) { [playback] in
            playback.pauseIfNeeded()
        }
    }

    /// Cancels an in-progress export.
    func cancelExport() {
        export.cancelExport()
    }

    /// Cleans up the exported temp file.
    func cleanUpExportedFile() {
        export.cleanUpExportedFile()
    }

    /// Removes a missing-media video from the project and rebuilds players.
    ///
    /// - Parameter id: Video identity to remove.
    func removeMissingVideo(id: UUID) {
        guard let index = project.index(forVideoID: id) else { return }
        let wasPlaying = playback.isPlaying
        playback.pauseIfNeeded()
        projectStore.deleteMedia(for: project.videos[index], projectID: project.id)
        project.removeVideo(id: id)
        playback.rebuildPlayers()
        if wasPlaying, !playback.players.isEmpty {
            playback.resumePlayback()
        }
    }

    /// Whether a video has content at the given timeline position.
    ///
    /// - Parameters:
    ///   - index: Video index.
    ///   - timelineSeconds: Position on the timeline.
    /// - Returns: True if the video's local time is within its duration.
    func isVideoActive(index: Int, at timelineSeconds: Double) -> Bool {
        playback.isVideoActive(index: index, at: timelineSeconds)
    }

    /// Returns a human-readable label for an inactive video panel.
    ///
    /// - Parameters:
    ///   - index: Video index.
    ///   - timelineSeconds: Current playhead position.
    /// - Returns: A label like "Starts in 0:04" or "Ended", or nil if active.
    func inactiveLabel(forIndex index: Int, at timelineSeconds: Double) -> String? {
        playback.inactiveLabel(forIndex: index, at: timelineSeconds)
    }

    /// Nudges a video's sync offset and immediately reapplies playback planning.
    ///
    /// - Parameters:
    ///   - index: Video display index.
    ///   - deltaSeconds: Offset delta to add.
    func nudgeSyncOffset(index: Int, deltaSeconds: Double) {
        guard project.videos.indices.contains(index) else { return }
        project.videos[index].syncOffsetSeconds += deltaSeconds
        playback.seekAfterProjectTimingChange()
    }

    /// Re-runs audio sync from the workspace and updates per-video offsets/status.
    func resyncProject() {
        guard !isResyncing, project.videos.count >= 2 else { return }
        let wasPlaying = playback.isPlaying
        playback.pauseIfNeeded()
        isResyncing = true
        export.exportError = nil
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
                    playback.settleCurrentSeek(resumeAfterSeek: wasPlaying)
                }
            } catch {
                await MainActor.run {
                    isResyncing = false
                    export.exportError = error.localizedDescription
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

    /// Pauses all players, saves, and removes observers.
    func tearDown() {
        countIn.cancel()
        playback.tearDown()
        export.tearDown()
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
    }
}

// MARK: - Private Sync

private extension WorkspaceViewModel {
    /// Keeps child controllers aligned with parent project state.
    func syncChildrenFromProject() {
        playback.updateProject(project)
        annotations.updateAnnotations(project.annotations)
        rebuildScrubSnapTargets()
    }

    /// Writes annotation store changes back into the project.
    func syncProjectAnnotationsFromStore() {
        project.annotations = annotations.annotations
    }

    /// Rebuilds cached scrub snap landmarks after landmark sources change.
    func rebuildScrubSnapTargets() {
        scrubSnapTargets = ScrubSnapTargets.build(
            annotations: project.annotations,
            speedSegments: project.speedSegments,
            timelineStart: project.timelineStartSeconds,
            timelineEnd: project.timelineEndSeconds
        )
    }
}

// MARK: - Private Lifecycle

private extension WorkspaceViewModel {
    /// Pauses players when the app backgrounds and resumes on foreground.
    func observeAppLifecycle() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                saveImmediately()
                wasPlayingBeforeBackground = playback.isPlaying
                playback.pauseIfNeeded()
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
                playback.resumePlayback()
            }
        }
    }

    /// Observes audio interruptions.
    func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }
    }

    /// Handles audio interruptions by pausing UI and player state together.
    ///
    /// - Parameter notification: Audio interruption notification.
    func handleAudioInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        switch type {
        case .began:
            wasPlayingBeforeBackground = playback.isPlaying
            playback.pauseIfNeeded()
        case .ended:
            if wasPlayingBeforeBackground {
                wasPlayingBeforeBackground = false
                playback.resumePlayback()
            }
        @unknown default:
            break
        }
    }
}

// MARK: - Private Autosave

private extension WorkspaceViewModel {
    /// Schedules a debounced autosave after project mutations.
    func scheduleAutosave() {
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
    func saveImmediately() {
        autosaveTask?.cancel()
        autosaveTask = nil
        try? projectStore.save(project)
    }
}
