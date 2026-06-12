// WorkspaceView.swift
// Coreo
//
// Screen 2 — the main workspace. Displays synced multi-angle videos
// in a split-screen grid with playback controls, an expandable edit
// tools panel, and the unified timeline. Designed as a viewer first:
// edit tools are discoverable but hidden by default.

import SwiftUI

/// The main workspace screen. Owns the WorkspaceViewModel and composes
/// the video grid, playback controls, edit tools, and timeline.
struct WorkspaceView: View {
    @State private var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    /// Coral accent used for interactive elements.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Deep background matching the app's dark theme.
    private let bgColor = Color(red: 0.04, green: 0.04, blue: 0.04)

    /// Creates the workspace for the given project.
    ///
    /// - Parameter project: A fully-synced CoreoProject ready for playback.
    init(project: CoreoProject) {
        _viewModel = State(wrappedValue: WorkspaceViewModel(project: project))
    }

    var body: some View {
        @Bindable var bindableExport = viewModel.export

        VStack(spacing: 0) {
            // MARK: Top Bar

            topBar

            // MARK: Edit Tools (expandable)

            if viewModel.isEditToolsVisible {
                editToolsPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !viewModel.missingVideos.isEmpty {
                missingMediaPanel
            }

            // MARK: Video Grid

            GeometryReader { geometry in
                ZStack {
                    VideoGridView(
                        viewModel: viewModel,
                        playback: viewModel.playback,
                        containerSize: geometry.size
                    )

                    if let hold = viewModel.playback.activeHoldEvent {
                        holdIndicator(hold)
                    }

                    // Annotation overlay — always displays annotations; editing is mode-gated.
                    AnnotationOverlayView(
                        viewModel: viewModel,
                        annotationStore: viewModel.annotations,
                        playback: viewModel.playback,
                        containerSize: geometry.size
                    )
                }
            }

            // MARK: Speed Control (expandable)

            if viewModel.isSpeedControlVisible {
                SpeedControlView(viewModel: viewModel, playback: viewModel.playback)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // MARK: Playback Controls

            PlaybackControlsView(viewModel: viewModel, playback: viewModel.playback)

            // MARK: Timeline

            TimelineView(viewModel: viewModel, playback: viewModel.playback)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        .background(bgColor.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(viewModel.playback.isPlaying && !viewModel.isEditToolsVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isEditToolsVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isAnnotationMode)
        .overlay {
            if viewModel.export.isExporting {
                ExportProgressView(
                    progress: viewModel.export.exportProgress,
                    onCancel: { viewModel.cancelExport() }
                )
            }
        }
        .onDisappear {
            viewModel.tearDown()
        }
        .sheet(isPresented: $bindableExport.showShareSheet, onDismiss: {
            viewModel.cleanUpExportedFile()
        }) {
            if let url = viewModel.export.exportedVideoURL {
                ShareSheetView(activityItems: [url])
            }
        }
        .alert("Export Failed", isPresented: .init(
            get: { viewModel.export.exportError != nil },
            set: { if !$0 { bindableExport.exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.export.exportError ?? "")
        }
    }

    // MARK: - Top Bar

    /// Custom navigation bar with back, title, edit toggle, and export.
    private var topBar: some View {
        HStack(spacing: Spacing.md) {
            // Back button
            Button {
                Haptic.light()
                if viewModel.playback.isPlaying {
                    viewModel.togglePlayback()
                }
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.coreoToolbar)

            Spacer()

            Text(viewModel.project.name)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            // Edit tools toggle
            Button {
                Haptic.light()
                withAnimation(CoreoAnimation.standard) {
                    viewModel.isEditToolsVisible.toggle()
                    if !viewModel.isEditToolsVisible, viewModel.isAnnotationMode {
                        viewModel.exitAnnotationMode()
                    }
                }
            } label: {
                Image(systemName: viewModel.isEditToolsVisible
                    ? "pencil.circle.fill"
                    : "pencil.circle")
                    .font(.title3)
                    .foregroundColor(
                        viewModel.isEditToolsVisible ? accentCoral : .white.opacity(0.8)
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.coreoToolbar)

            // Export
            Button {
                Haptic.medium()
                viewModel.startExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .foregroundColor(viewModel.export.isExporting ? .white.opacity(0.35) : .white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.coreoToolbar)
            .disabled(viewModel.export.isExporting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1).opacity(0.95))
    }

    // MARK: - Edit Tools Panel

    /// Expandable panel with annotation, speed, audio, and sync tools.
    @ViewBuilder
    private var editToolsPanel: some View {
        @Bindable var bindableViewModel = viewModel
        @Bindable var bindableAnnotations = viewModel.annotations

        VStack(spacing: Spacing.md) {
            // Row 1: Annotation tools
            AnnotationToolbar(
                viewModel: viewModel,
                selectedTool: $bindableAnnotations.selectedAnnotationTool,
                selectedColorHex: $bindableAnnotations.selectedAnnotationColorHex
            )

            if let selectedID = viewModel.annotations.selectedAnnotationID,
               annotationExists(id: selectedID) {
                AnnotationTimeRangeControl(
                    startTimeSeconds: timingStartBinding(id: selectedID),
                    durationSeconds: timingDurationBinding(id: selectedID),
                    isPersistent: timingPersistentBinding(id: selectedID),
                    timelineStart: viewModel.timelineStart,
                    timelineEnd: viewModel.timelineEnd
                )
                .transition(.opacity)
            }

            Divider().background(Color.white.opacity(0.15))

            // Row 2: Speed/Hold + Audio Source + Export Aspect
            HStack(spacing: Spacing.lg) {
                // Speed control toggle
                Button {
                    Haptic.tick()
                    withAnimation(CoreoAnimation.standard) {
                        bindableViewModel.isSpeedControlVisible.toggle()
                    }
                } label: {
                    Label("Speed", systemImage: "gauge.medium")
                        .font(.caption)
                        .foregroundColor(
                            viewModel.isSpeedControlVisible ? accentCoral : .white.opacity(0.7)
                        )
                        .frame(minHeight: 44)
                }
                .buttonStyle(.coreoToolbar)

                toolDivider

                audioSourceSelector

                toolDivider

                Button {
                    Haptic.medium()
                    viewModel.resyncProject()
                } label: {
                    Label(viewModel.isResyncing ? "Syncing" : "Re-sync", systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(viewModel.isResyncing ? accentCoral : .white.opacity(0.7))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.coreoToolbar)
                .disabled(viewModel.isResyncing)

                toolDivider

                // Export aspect ratio picker
                exportAspectPicker

                Spacer()
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1).opacity(0.95))
    }

    /// Returns whether an annotation exists in the current store.
    ///
    /// - Parameter id: Annotation identity.
    /// - Returns: True when the annotation is present.
    private func annotationExists(id: UUID) -> Bool {
        viewModel.annotations.annotations.contains { $0.id == id }
    }

    /// Builds a binding to an annotation's start time.
    ///
    /// - Parameter id: Annotation identity.
    /// - Returns: Binding that persists changes through the workspace model.
    private func timingStartBinding(id: UUID) -> Binding<Double> {
        Binding(
            get: { annotationValue(id: id, keyPath: \.startTimeSeconds) ?? viewModel.timelineStart },
            set: { newValue in
                updateAnnotationTiming(id: id, startTimeSeconds: newValue)
            }
        )
    }

    /// Builds a binding to an annotation's duration.
    ///
    /// - Parameter id: Annotation identity.
    /// - Returns: Binding that persists changes through the workspace model.
    private func timingDurationBinding(id: UUID) -> Binding<Double> {
        Binding(
            get: { annotationValue(id: id, keyPath: \.durationSeconds) ?? 0 },
            set: { newValue in
                updateAnnotationTiming(id: id, durationSeconds: newValue)
            }
        )
    }

    /// Builds a binding to an annotation's persistence flag.
    ///
    /// - Parameter id: Annotation identity.
    /// - Returns: Binding that persists changes through the workspace model.
    private func timingPersistentBinding(id: UUID) -> Binding<Bool> {
        Binding(
            get: { annotationValue(id: id, keyPath: \.isPersistent) ?? false },
            set: { newValue in
                updateAnnotationTiming(id: id, isPersistent: newValue)
            }
        )
    }

    /// Reads one annotation value from the store.
    ///
    /// - Parameters:
    ///   - id: Annotation identity.
    ///   - keyPath: Annotation property to read.
    /// - Returns: The stored value when available.
    private func annotationValue<Value>(
        id: UUID,
        keyPath: KeyPath<TimedAnnotation, Value>
    ) -> Value? {
        viewModel.annotations.annotations.first { $0.id == id }?[keyPath: keyPath]
    }

    /// Persists a partial timing update for one annotation.
    ///
    /// - Parameters:
    ///   - id: Annotation identity.
    ///   - startTimeSeconds: Optional replacement start time.
    ///   - durationSeconds: Optional replacement duration.
    ///   - isPersistent: Optional replacement persistence flag.
    private func updateAnnotationTiming(
        id: UUID,
        startTimeSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        isPersistent: Bool? = nil
    ) {
        guard let annotation = viewModel.annotations.annotations.first(where: { $0.id == id }) else {
            return
        }
        viewModel.updateAnnotationTiming(
            id: id,
            startTimeSeconds: startTimeSeconds ?? annotation.startTimeSeconds,
            durationSeconds: durationSeconds ?? annotation.durationSeconds,
            isPersistent: isPersistent ?? annotation.isPersistent
        )
    }

    /// Warning panel for copied media files missing from disk.
    private var missingMediaPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.missingVideos) { video in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(accentCoral)
                    Text("\(video.originalFilename) is missing")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    Button("Remove") {
                        viewModel.removeMissingVideo(id: video.id)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(accentCoral)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.13, green: 0.11, blue: 0.1))
    }

    /// Thin vertical divider for the edit tools row.
    private var toolDivider: some View {
        Divider()
            .frame(height: 16)
            .background(Color.white.opacity(0.15))
    }

    /// Visible indicator for an intentional live hold.
    ///
    /// - Parameter event: Active hold event.
    /// - Returns: Hold indicator view.
    private func holdIndicator(_ event: HoldPlaybackCoordinator.HoldEvent) -> some View {
        VStack {
            HStack {
                Spacer()
                Label(
                    "Hold \(TimeFormatting.formatShort(event.wallDurationSeconds))",
                    systemImage: "pause.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(12)
    }

    /// Menu for switching the active audio source among imported videos.
    private var audioSourceSelector: some View {
        Menu {
            ForEach(
                Array(viewModel.project.videos.enumerated()),
                id: \.element.id
            ) { index, video in
                Button {
                    viewModel.setAudioSource(index: index)
                } label: {
                    HStack {
                        Text(video.originalFilename)
                        if index == viewModel.project.audioSourceIndex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "speaker.wave.2")
                Text("Audio")
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.7))
        }
    }

    /// Picker for export aspect ratio (landscape/portrait/square).
    @ViewBuilder
    private var exportAspectPicker: some View {
        @Bindable var bindableExport = viewModel.export

        Menu {
            ForEach(ExportAspectRatio.allCases) { ratio in
                Button {
                    Haptic.tick()
                    bindableExport.exportAspectRatio = ratio
                } label: {
                    HStack {
                        Image(systemName: ratio.iconName)
                        Text(ratio.rawValue)
                        if ratio == viewModel.export.exportAspectRatio {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: viewModel.export.exportAspectRatio.iconName)
                Text(viewModel.export.exportAspectRatio.rawValue)
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.7))
        }
    }
}
