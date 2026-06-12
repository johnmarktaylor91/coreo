// VideoPanelView.swift
// Coreo
//
// Individual video panel that wraps an AVPlayer in a performant
// AVPlayerLayer-backed UIView. Supports crop rects, pinch-to-zoom,
// and inactive-state overlays for videos outside their time range.

import AVFoundation
import SwiftUI

// MARK: - VideoPanelView

/// A single video panel in the split-screen grid. Renders an AVPlayer
/// via a hardware-accelerated AVPlayerLayer and overlays inactive-state
/// labels when the video has no content at the current timeline position.
struct VideoPanelView: View {
    /// The AVPlayer whose output this panel displays.
    let player: AVPlayer

    /// Optional normalized (0-1) crop region. Nil means show the full frame.
    let cropRect: CGRect?

    /// Whether the preview should be flipped horizontally.
    let isMirrored: Bool

    /// Whether this panel's audio is currently muted.
    let isMuted: Bool

    /// Whether this video has content at the current playhead position.
    let isActive: Bool

    /// Label to show when the video is inactive (e.g., "Starts in 0:04").
    let inactiveLabel: String?

    /// Compact sync status label.
    let syncStatusLabel: String

    /// Whether this panel is the sync reference.
    let isReference: Bool

    /// Called when the user nudges sync by a delta.
    let onNudgeSync: (Double) -> Void

    /// Called when the user opens expanded waveform sync.
    let onExpandSync: () -> Void

    /// Called when the user toggles this panel's audio.
    let onToggleMute: () -> Void

    /// Called when the user toggles this panel's mirror mode.
    let onToggleMirror: () -> Void

    /// Accumulated pinch-to-zoom scale.
    @State private var currentScale: CGFloat = 1.0

    /// Scale from the in-progress magnification gesture.
    @State private var gestureScale: CGFloat = 1.0

    /// Pan offset for repositioning after zoom.
    @State private var panOffset: CGSize = .zero

    /// Offset from the in-progress drag gesture.
    @State private var gestureDragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Video layer — always present so AVPlayer keeps its attachment.
                AVPlayerLayerView(player: player, cropRect: cropRect, isMirrored: isMirrored)
                    .scaleEffect(currentScale * gestureScale)
                    .offset(
                        x: panOffset.width + gestureDragOffset.width,
                        y: panOffset.height + gestureDragOffset.height
                    )

                // Dark overlay for inactive videos.
                if !isActive {
                    Color.black.opacity(0.75)

                    if let label = inactiveLabel {
                        Text(label)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                VStack {
                    HStack {
                        syncStatusBadge
                        Spacer()
                        panelUtilityControls
                        syncNudgeControls
                    }
                    Spacer()
                }
                .padding(6)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnificationGesture)
            .gesture(dragGesture)
            .onTapGesture(count: 2) {
                Haptic.light()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    currentScale = 1.0
                    gestureScale = 1.0
                    panOffset = .zero
                    gestureDragOffset = .zero
                }
            }
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Unobtrusive sync status badge.
    private var syncStatusBadge: some View {
        Text(syncStatusLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.78))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Small per-panel manual sync nudge controls.
    private var syncNudgeControls: some View {
        Group {
            if !isReference {
                HStack(spacing: 4) {
                    syncExpandButton
                    syncNudgeButton(label: "-1f", delta: -1.0 / 30.0)
                    syncNudgeButton(label: "+1f", delta: 1.0 / 30.0)
                    syncNudgeButton(label: "-.1", delta: -0.1)
                    syncNudgeButton(label: "+.1", delta: 0.1)
                }
            }
        }
    }

    /// Opens the expanded waveform nudge view.
    private var syncExpandButton: some View {
        Button {
            Haptic.tick()
            onExpandSync()
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(CoreoColor.accent)
                .frame(width: 28, height: 24)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open waveform sync")
    }

    /// Mirror and audio buttons for one panel.
    private var panelUtilityControls: some View {
        HStack(spacing: 4) {
            panelIconButton(
                systemName: isMirrored ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill" : "arrow.left.and.right",
                label: isMirrored ? "Disable mirror mode" : "Enable mirror mode",
                isActive: isMirrored,
                action: onToggleMirror
            )
            panelIconButton(
                systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: isMuted ? "Unmute angle audio" : "Mute angle audio",
                isActive: !isMuted,
                action: onToggleMute
            )
        }
    }

    /// Builds one icon-only utility button.
    ///
    /// - Parameters:
    ///   - systemName: SF Symbol name.
    ///   - label: Accessibility label.
    ///   - isActive: Whether the button represents active state.
    ///   - action: Button action.
    /// - Returns: A utility button view.
    private func panelIconButton(
        systemName: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptic.tick()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? CoreoColor.accent : .white.opacity(0.82))
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Builds one sync nudge button.
    ///
    /// - Parameters:
    ///   - label: Button label.
    ///   - delta: Sync offset delta.
    /// - Returns: A nudge button view.
    private func syncNudgeButton(label: String, delta: Double) -> some View {
        Button {
            Haptic.tick()
            onNudgeSync(delta)
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 28, height: 24)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gestures

    /// Pinch-to-zoom gesture. Clamped to 1x-5x with rubber-band beyond limits.
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let raw = currentScale * value
                // Rubber-band: allow slight overshoot beyond limits for physical feel.
                if raw < 1.0 {
                    gestureScale = value * 0.3 + 0.7 // Resist going below 1x
                } else if raw > 5.0 {
                    let excess = raw - 5.0
                    gestureScale = (5.0 + excess * 0.2) / currentScale
                } else {
                    gestureScale = value
                }
            }
            .onEnded { value in
                let newScale = max(1.0, min(currentScale * value, 5.0))
                // Haptic at limits
                if currentScale * value < 1.0 || currentScale * value > 5.0 {
                    Haptic.light()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    currentScale = newScale
                    gestureScale = 1.0
                    if newScale <= 1.0 {
                        panOffset = .zero
                    }
                }
            }
    }

    /// Drag gesture for panning within a zoomed panel.
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard currentScale > 1.0 else { return }
                gestureDragOffset = value.translation
            }
            .onEnded { value in
                guard currentScale > 1.0 else { return }
                panOffset = CGSize(
                    width: panOffset.width + value.translation.width,
                    height: panOffset.height + value.translation.height
                )
                gestureDragOffset = .zero
            }
    }
}

// MARK: - AVPlayerLayerView (UIViewRepresentable)

/// A SwiftUI wrapper around a UIView whose backing layer is an AVPlayerLayer.
/// This provides hardware-accelerated, low-latency video rendering that
/// outperforms the built-in VideoPlayer for synchronized multi-angle playback.
struct AVPlayerLayerView: UIViewRepresentable {
    /// The player to render.
    let player: AVPlayer

    /// Optional normalized crop rect. When set, the player layer displays
    /// the same source region that export crops.
    let cropRect: CGRect?

    /// Whether the layer should be flipped horizontally.
    let isMirrored: Bool

    func makeUIView(context _: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context _: Context) {
        // Update player reference if it changed.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }

        if uiView.playerLayer.videoGravity != .resizeAspect {
            uiView.playerLayer.videoGravity = .resizeAspect
        }

        uiView.cropRect = cropRect
        uiView.isMirrored = isMirrored
    }
}

// MARK: - PlayerUIView

/// A UIView subclass whose layer class is AVPlayerLayer, giving us direct
/// control over video rendering without an extra sublayer.
final class PlayerUIView: UIView {
    /// Last layer contents rect applied.
    private var lastContentsRect: CGRect = .null

    /// Optional normalized crop rect.
    var cropRect: CGRect? {
        didSet {
            guard cropRect != oldValue else { return }
            updateLayerGeometryIfNeeded()
        }
    }

    /// Whether this layer should be flipped horizontally.
    var isMirrored: Bool = false {
        didSet {
            guard isMirrored != oldValue else { return }
            updateLayerGeometryIfNeeded()
        }
    }

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    /// Typed accessor for the backing AVPlayerLayer.
    var playerLayer: AVPlayerLayer {
        // Safe: layerClass guarantees the layer type.
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    /// Applies crop and mirror geometry only when needed.
    private func updateLayerGeometryIfNeeded() {
        let contentsRect = CropGeometry.previewContentsRect(for: cropRect)
        if contentsRect != lastContentsRect {
            playerLayer.contentsRect = contentsRect
            lastContentsRect = contentsRect
        }
        playerLayer.setAffineTransform(isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
    }
}
