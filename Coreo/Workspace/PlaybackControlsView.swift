// PlaybackControlsView.swift
// Coreo
//
// Playback control bar between the video grid and timeline. Shows
// current time, play/pause, and a speed selector. Designed to be
// minimal and unobtrusive in the default viewer state.

import SwiftUI

/// Horizontal playback controls: time display, play/pause, speed picker.
struct PlaybackControlsView: View {
    /// Workspace view model for playback state and actions.
    let viewModel: WorkspaceViewModel

    /// Playback controller for state and actions.
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Left — Time Display

            timeDisplay
                .frame(maxWidth: .infinity, alignment: .leading)

            // MARK: Center — Play/Pause

            playPauseButton

            // MARK: Right — Speed Picker

            speedButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: 44)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Time Display

    /// Shows "current / total" formatted time.
    private var timeDisplay: some View {
        Text(
            "\(TimeFormatting.formatShort(playback.currentTimeSeconds))"
                + " / "
                + "\(TimeFormatting.formatShort(viewModel.timelineDuration))"
        )
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(CoreoColor.textSecondary)
    }

    // MARK: - Play / Pause

    /// Large central play/pause toggle.
    private var playPauseButton: some View {
        Button {
            Haptic.light()
            viewModel.togglePlayback()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.coreoToolbar)
    }

    // MARK: - Speed Picker

    /// Speed indicator that opens a horizontal picker on tap.
    @ViewBuilder
    private var speedButton: some View {
        @Bindable var bindablePlayback = playback

        Button {
            Haptic.tick()
            withAnimation(CoreoAnimation.standard) {
                playback.isSpeedPickerVisible.toggle()
            }
        } label: {
            Text(speedLabel)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(playback.playbackRate == 1.0 ? CoreoColor.textSecondary : CoreoColor.accent)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .fill(Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.coreo)
        .popover(isPresented: $bindablePlayback.isSpeedPickerVisible) {
            speedPickerContent
                .frame(width: 260, height: 52)
        }
    }

    /// Formatted speed label (e.g., "1x", "0.5x").
    private var speedLabel: String {
        let rate = playback.playbackRate
        if rate == Float(Int(rate)) {
            return "\(Int(rate))x"
        }
        return String(format: "%.2gx", rate)
    }

    /// Horizontal row of speed options shown in the popover.
    private var speedPickerContent: some View {
        HStack(spacing: Spacing.md) {
            ForEach(PlaybackController.availableRates, id: \.self) { rate in
                Button {
                    Haptic.tick()
                    playback.setPlaybackRate(rate)
                    playback.isSpeedPickerVisible = false
                } label: {
                    let label: String = {
                        if rate == Float(Int(rate)) {
                            return "\(Int(rate))x"
                        }
                        return String(format: "%.2gx", rate)
                    }()

                    Text(label)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(rate == playback.playbackRate ? .bold : .regular)
                        .foregroundColor(rate == playback.playbackRate ? CoreoColor.accent : .white)
                        .frame(minHeight: 36)
                        .padding(.horizontal, Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.medium)
                                .fill(
                                    rate == playback.playbackRate
                                        ? CoreoColor.accent.opacity(0.15)
                                        : Color.clear
                                )
                        )
                }
                .buttonStyle(.coreo)
            }
        }
        .padding(Spacing.lg)
        .background(CoreoColor.backgroundMedium)
    }
}
