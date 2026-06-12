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
    @StateObject private var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    /// Coral accent used for interactive elements.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Deep background matching the app's dark theme.
    private let bgColor = Color(red: 0.04, green: 0.04, blue: 0.04)

    /// Creates the workspace for the given project.
    ///
    /// - Parameter project: A fully-synced CoreoProject ready for playback.
    init(project: CoreoProject) {
        _viewModel = StateObject(wrappedValue: WorkspaceViewModel(project: project))
    }

    var body: some View {
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
                        containerSize: geometry.size
                    )

                    if let hold = viewModel.activeHoldEvent {
                        holdIndicator(hold)
                    }

                    // Annotation overlay — renders existing annotations + creation tools.
                    if viewModel.isAnnotationMode {
                        AnnotationOverlayView(
                            viewModel: viewModel,
                            containerSize: geometry.size
                        )
                    }
                }
            }

            // MARK: Speed Control (expandable)
            if viewModel.isSpeedControlVisible {
                SpeedControlView(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // MARK: Playback Controls
            PlaybackControlsView(viewModel: viewModel)

            // MARK: Timeline
            TimelineView(viewModel: viewModel)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        .background(bgColor.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(viewModel.isPlaying && !viewModel.isEditToolsVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isEditToolsVisible)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isAnnotationMode)
        .overlay {
            if viewModel.isExporting {
                ExportProgressView(
                    progress: viewModel.exportProgress,
                    onCancel: { viewModel.cancelExport() }
                )
            }
        }
        .onDisappear {
            viewModel.tearDown()
        }
        .sheet(isPresented: $viewModel.showShareSheet, onDismiss: {
            viewModel.cleanUpExportedFile()
        }) {
            if let url = viewModel.exportedVideoURL {
                ShareSheetView(activityItems: [url])
            }
        }
        .alert("Export Failed", isPresented: .init(
            get: { viewModel.exportError != nil },
            set: { if !$0 { viewModel.exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.exportError ?? "")
        }
    }

    // MARK: - Top Bar

    /// Custom navigation bar with back, title, edit toggle, and export.
    private var topBar: some View {
        HStack(spacing: Spacing.md) {
            // Back button
            Button {
                Haptic.light()
                if viewModel.isPlaying {
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
                    if !viewModel.isEditToolsVisible && viewModel.isAnnotationMode {
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
                    .foregroundColor(viewModel.isExporting ? .white.opacity(0.35) : .white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.coreoToolbar)
            .disabled(viewModel.isExporting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1).opacity(0.95))
    }

    // MARK: - Edit Tools Panel

    /// Expandable panel with annotation, speed, audio, and sync tools.
    private var editToolsPanel: some View {
        VStack(spacing: Spacing.md) {
            // Row 1: Annotation tools
            AnnotationToolbar(
                viewModel: viewModel,
                selectedTool: $viewModel.selectedAnnotationTool,
                selectedColorHex: $viewModel.selectedAnnotationColorHex
            )

            Divider().background(Color.white.opacity(0.15))

            // Row 2: Speed/Hold + Audio Source + Export Aspect
            HStack(spacing: Spacing.lg) {
                // Speed control toggle
                Button {
                    Haptic.tick()
                    withAnimation(CoreoAnimation.standard) {
                        viewModel.isSpeedControlVisible.toggle()
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
    private var exportAspectPicker: some View {
        Menu {
            ForEach(ExportAspectRatio.allCases) { ratio in
                Button {
                    Haptic.tick()
                    viewModel.exportAspectRatio = ratio
                } label: {
                    HStack {
                        Image(systemName: ratio.iconName)
                        Text(ratio.rawValue)
                        if ratio == viewModel.exportAspectRatio {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: viewModel.exportAspectRatio.iconName)
                Text(viewModel.exportAspectRatio.rawValue)
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.7))
        }
    }
}
