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

            // MARK: Center — Loop + Frame Step + Play/Pause

            HStack(spacing: Spacing.sm) {
                loopButton
                frameStepButton(direction: -1)
                playPauseButton
                frameStepButton(direction: 1)
                countInToggle
            }

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
            Image(systemName: playback.isPlaying || viewModel.countIn.isActive ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.coreoToolbar)
        .accessibilityLabel(playback.isPlaying || viewModel.countIn.isActive ? "Pause" : "Play")
    }

    /// A-B loop activation and clear button.
    private var loopButton: some View {
        Button {
            let result = viewModel.activateLoopControl()
            switch result {
            case .armed, .activated, .cleared:
                Haptic.tick()
            case .rejectedTooShort:
                Haptic.error()
            }
        } label: {
            Image(systemName: loopIconName)
                .font(.body.weight(.semibold))
                .foregroundColor(loopTint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.coreoToolbar)
        .accessibilityLabel(loopAccessibilityLabel)
    }

    /// Count-in preference toggle.
    private var countInToggle: some View {
        @Bindable var bindableCountIn = viewModel.countIn

        return Toggle(isOn: $bindableCountIn.isEnabled) {
            Image(systemName: "timer")
                .font(.body.weight(.semibold))
                .foregroundColor(viewModel.countIn.isEnabled ? CoreoColor.accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .toggleStyle(.button)
        .buttonStyle(.coreoToolbar)
        .accessibilityLabel(viewModel.countIn.isEnabled ? "Count-in on" : "Count-in off")
    }

    /// System icon for the current loop state.
    private var loopIconName: String {
        switch playback.loopState {
        case .cleared:
            "repeat"
        case .armed:
            "a.circle.fill"
        case .active:
            "repeat.circle.fill"
        }
    }

    /// Foreground tint for the current loop state.
    private var loopTint: Color {
        switch playback.loopState {
        case .cleared:
            .white.opacity(0.72)
        case .armed:
            .yellow
        case .active:
            CoreoColor.accent
        }
    }

    /// VoiceOver label for the current loop state.
    private var loopAccessibilityLabel: String {
        switch playback.loopState {
        case .cleared:
            "Set loop start"
        case .armed:
            "Set loop end"
        case .active:
            "Clear A-B loop"
        }
    }

    /// One-frame step button.
    ///
    /// - Parameter direction: -1 for backward, +1 for forward.
    /// - Returns: A frame-step button.
    private func frameStepButton(direction: Int) -> some View {
        Button {
            Haptic.tick()
            viewModel.stepFrame(direction: direction)
        } label: {
            Image(systemName: direction < 0 ? "backward.frame.fill" : "forward.frame.fill")
                .font(.body.weight(.semibold))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.coreoToolbar)
        .accessibilityLabel(direction < 0 ? "Step back one frame" : "Step forward one frame")
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
        .accessibilityLabel("Playback speed \(speedLabel)")
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
