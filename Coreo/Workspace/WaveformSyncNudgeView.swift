// WaveformSyncNudgeView.swift
// Coreo
//
// Expanded waveform alignment UI for manual sync nudging.

import SwiftUI

/// Sheet that aligns one selected clip against the reference waveform.
struct WaveformSyncNudgeView: View {
    /// Workspace state and actions.
    let viewModel: WorkspaceViewModel

    /// Selected non-reference video index.
    let videoIndex: Int

    /// Sheet dismiss action.
    let onDone: () -> Void

    @State private var dragStartOffset: Double?

    private let windowSeconds: Double = 6
    private let frameStepSeconds: Double = 1.0 / 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            waveformStack
            precisionControls
        }
        .padding(Spacing.lg)
        .background(CoreoColor.backgroundDeep)
        .presentationDetents([.height(360), .medium])
        .onAppear {
            viewModel.loadWaveformEnvelopeIfNeeded(index: viewModel.project.referenceVideoIndex)
            viewModel.loadWaveformEnvelopeIfNeeded(index: videoIndex)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Waveform Sync")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(currentOffsetLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(CoreoColor.accent)
            }

            Spacer()

            Button("Reset") {
                Haptic.tick()
                viewModel.resetSyncOffset(index: videoIndex)
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(CoreoColor.accent)
            .frame(minHeight: 44)

            Button("Done") {
                onDone()
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.white)
            .frame(minHeight: 44)
        }
    }

    private var waveformStack: some View {
        GeometryReader { geometry in
            let secondsPerPoint = windowSeconds / max(Double(geometry.size.width), 1)
            ZStack {
                VStack(spacing: Spacing.md) {
                    waveformStrip(
                        title: "Reference",
                        envelope: referenceEnvelope,
                        clipOffsetSeconds: referenceOffset,
                        width: geometry.size.width,
                        isDraggable: false,
                        secondsPerPoint: secondsPerPoint
                    )
                    waveformStrip(
                        title: selectedFilename,
                        envelope: selectedEnvelope,
                        clipOffsetSeconds: currentOffset,
                        width: geometry.size.width,
                        isDraggable: true,
                        secondsPerPoint: secondsPerPoint
                    )
                }

                Rectangle()
                    .fill(CoreoColor.accent)
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 170)
    }

    private var precisionControls: some View {
        HStack(spacing: Spacing.sm) {
            offsetButton(label: "-1f", delta: -frameStepSeconds)
            offsetButton(label: "+1f", delta: frameStepSeconds)
            offsetButton(label: "-0.1s", delta: -0.1)
            offsetButton(label: "+0.1s", delta: 0.1)
            Spacer()
        }
    }

    /// Renders one labeled waveform row.
    ///
    /// - Parameters:
    ///   - title: Row title.
    ///   - envelope: Cached envelope or nil while loading.
    ///   - clipOffsetSeconds: Canonical sync offset for this clip.
    ///   - width: Available strip width.
    ///   - isDraggable: Whether horizontal drag should edit sync.
    ///   - secondsPerPoint: Drag scale.
    /// - Returns: A labeled waveform row.
    private func waveformStrip(
        title: String,
        envelope: WaveformEnvelope?,
        clipOffsetSeconds: Double,
        width: CGFloat,
        isDraggable: Bool,
        secondsPerPoint: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(CoreoColor.textSecondary)
                .lineLimit(1)

            waveformStripContent(
                envelope: envelope,
                clipOffsetSeconds: clipOffsetSeconds,
                width: width,
                isDraggable: isDraggable,
                secondsPerPoint: secondsPerPoint
            )
        }
    }

    /// Builds waveform strip content with optional drag behavior.
    ///
    /// - Parameters:
    ///   - envelope: Cached envelope or nil while loading.
    ///   - clipOffsetSeconds: Canonical sync offset for this clip.
    ///   - width: Available strip width.
    ///   - isDraggable: Whether the row should accept drag edits.
    ///   - secondsPerPoint: Drag scale.
    /// - Returns: A waveform strip view.
    @ViewBuilder
    private func waveformStripContent(
        envelope: WaveformEnvelope?,
        clipOffsetSeconds: Double,
        width: CGFloat,
        isDraggable: Bool,
        secondsPerPoint: Double
    ) -> some View {
        let content = ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.small)
                .fill(CoreoColor.backgroundPanel)

            if envelope == nil {
                ProgressView()
                    .tint(CoreoColor.accent)
            } else if envelope?.hasAudio == false {
                Text("No audio")
                    .font(.caption)
                    .foregroundColor(CoreoColor.textTertiary)
            } else if let envelope {
                WaveformStripShape(
                    buckets: visibleBuckets(envelope: envelope, clipOffsetSeconds: clipOffsetSeconds, width: width),
                    maximumAmplitude: maxAmplitude(envelope)
                )
                .fill(isDraggable ? CoreoColor.accent.opacity(0.85) : .white.opacity(0.65))
                .padding(.vertical, 8)
            }
        }
        .frame(height: 58)
        .contentShape(Rectangle())
        .accessibilityLabel(isDraggable ? "Selected clip waveform" : "Reference waveform")

        if isDraggable {
            content.gesture(dragGesture(secondsPerPoint: secondsPerPoint))
        } else {
            content
        }
    }

    /// Creates a fixed sync nudge button.
    ///
    /// - Parameters:
    ///   - label: Button label.
    ///   - delta: Offset delta in seconds.
    /// - Returns: A nudge button.
    private func offsetButton(label: String, delta: Double) -> some View {
        Button {
            Haptic.tick()
            viewModel.nudgeSyncOffset(index: videoIndex, deltaSeconds: delta)
        } label: {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundColor(.white)
                .frame(minWidth: 54, minHeight: 44)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Nudge sync \(label)")
    }

    /// Creates the drag gesture that maps points to canonical offset seconds.
    ///
    /// - Parameter secondsPerPoint: Visible waveform scale.
    /// - Returns: Drag gesture for the selected strip.
    private func dragGesture(secondsPerPoint: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = dragStartOffset ?? currentOffset
                dragStartOffset = base
                let delta = WaveformEnvelopeBuilder.offsetDelta(
                    points: value.translation.width,
                    secondsPerPoint: secondsPerPoint
                )
                viewModel.setSyncOffset(index: videoIndex, offsetSeconds: base + delta)
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }

    private var referenceEnvelope: WaveformEnvelope? {
        let reference = viewModel.project.referenceVideoIndex
        guard viewModel.project.videos.indices.contains(reference) else { return nil }
        return viewModel.waveformEnvelopes[viewModel.project.videos[reference].id]
    }

    private var selectedEnvelope: WaveformEnvelope? {
        guard viewModel.project.videos.indices.contains(videoIndex) else { return nil }
        return viewModel.waveformEnvelopes[viewModel.project.videos[videoIndex].id]
    }

    private var currentOffset: Double {
        guard viewModel.project.videos.indices.contains(videoIndex) else { return 0 }
        return viewModel.project.videos[videoIndex].syncOffsetSeconds
    }

    private var referenceOffset: Double {
        let reference = viewModel.project.referenceVideoIndex
        guard viewModel.project.videos.indices.contains(reference) else { return 0 }
        return viewModel.project.videos[reference].syncOffsetSeconds
    }

    private var currentOffsetLabel: String {
        String(format: "%+.3fs", currentOffset)
    }

    private var selectedFilename: String {
        guard viewModel.project.videos.indices.contains(videoIndex) else { return "Selected" }
        return viewModel.project.videos[videoIndex].originalFilename
    }

    /// Returns visible amplitudes near the current playhead.
    ///
    /// - Parameters:
    ///   - envelope: Source envelope.
    ///   - clipOffsetSeconds: Canonical sync offset for this clip.
    ///   - width: Available strip width.
    /// - Returns: Amplitudes in the visible time window.
    private func visibleBuckets(
        envelope: WaveformEnvelope,
        clipOffsetSeconds: Double,
        width: CGFloat
    ) -> [Float] {
        guard width > 0 else { return [] }
        let playhead = viewModel.playback.currentTimeSeconds
        let clipLocalTime = playhead - clipOffsetSeconds
        let start = clipLocalTime - windowSeconds / 2
        let end = clipLocalTime + windowSeconds / 2
        let filtered = envelope.buckets.filter { bucket in
            bucket.startTimeSeconds + bucket.durationSeconds >= start
                && bucket.startTimeSeconds <= end
        }
        return filtered.map(\.amplitude)
    }

    /// Finds a safe normalization amplitude.
    ///
    /// - Parameter envelope: Source envelope.
    /// - Returns: Maximum positive amplitude.
    private func maxAmplitude(_ envelope: WaveformEnvelope) -> Float {
        max(envelope.buckets.map(\.amplitude).max() ?? 1, 0.0001)
    }
}

/// Compact filled waveform strip drawn from normalized amplitudes.
private struct WaveformStripShape: Shape {
    /// Amplitude values to render.
    let buckets: [Float]

    /// Maximum amplitude used for normalization.
    let maximumAmplitude: Float

    /// Draws vertical bars centered on the strip midline.
    ///
    /// - Parameter rect: Destination rectangle.
    /// - Returns: Waveform path.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !buckets.isEmpty else { return path }

        let step = rect.width / CGFloat(buckets.count)
        let midY = rect.midY
        for (index, amplitude) in buckets.enumerated() {
            let normalized = CGFloat(min(max(amplitude / maximumAmplitude, 0), 1))
            let height = max(1, normalized * rect.height)
            let x = rect.minX + CGFloat(index) * step
            path.addRect(CGRect(
                x: x,
                y: midY - height / 2,
                width: max(1, step * 0.82),
                height: height
            ))
        }
        return path
    }
}
