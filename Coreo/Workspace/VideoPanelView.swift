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

    /// Whether this video has content at the current playhead position.
    let isActive: Bool

    /// Label to show when the video is inactive (e.g., "Starts in 0:04").
    let inactiveLabel: String?

    /// Compact sync status label.
    let syncStatusLabel: String

    /// Called when the user nudges sync by a delta.
    let onNudgeSync: (Double) -> Void

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
                AVPlayerLayerView(player: player, cropRect: cropRect)
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
        HStack(spacing: 4) {
            syncNudgeButton(label: "-1f", delta: -1.0 / 30.0)
            syncNudgeButton(label: "+1f", delta: 1.0 / 30.0)
            syncNudgeButton(label: "-.1", delta: -0.1)
            syncNudgeButton(label: "+.1", delta: 0.1)
        }
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

    /// Optional normalized crop rect. When set, a CALayer mask is applied
    /// to show only the specified region of the video frame.
    let cropRect: CGRect?

    func makeUIView(context _: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = cropRect != nil ? .resizeAspectFill : .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context _: Context) {
        // Update player reference if it changed.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }

        // Update gravity based on crop presence.
        let gravity: AVLayerVideoGravity = cropRect != nil ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }

        uiView.cropRect = cropRect
    }
}

// MARK: - PlayerUIView

/// A UIView subclass whose layer class is AVPlayerLayer, giving us direct
/// control over video rendering without an extra sublayer.
final class PlayerUIView: UIView {
    /// Reused crop mask layer.
    private let cropMaskLayer = CAShapeLayer()

    /// Last bounds used to build the crop mask path.
    private var lastMaskBounds: CGRect = .null

    /// Last crop rect used to build the crop mask path.
    private var lastMaskCropRect: CGRect?

    /// Optional normalized crop rect.
    var cropRect: CGRect? {
        didSet {
            guard cropRect != oldValue else { return }
            setNeedsLayout()
        }
    }

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    /// Typed accessor for the backing AVPlayerLayer.
    var playerLayer: AVPlayerLayer {
        // Safe: layerClass guarantees the layer type.
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    /// Updates the crop mask after layout changes.
    override func layoutSubviews() {
        super.layoutSubviews()
        updateCropMaskIfNeeded()
    }

    /// Applies or removes the reusable crop mask.
    private func updateCropMaskIfNeeded() {
        guard let cropRect else {
            layer.mask = nil
            lastMaskCropRect = nil
            lastMaskBounds = .null
            return
        }

        guard bounds.width > 0, bounds.height > 0 else { return }
        guard cropRect != lastMaskCropRect || bounds != lastMaskBounds else { return }

        let maskFrame = CGRect(
            x: cropRect.origin.x * bounds.width,
            y: cropRect.origin.y * bounds.height,
            width: cropRect.size.width * bounds.width,
            height: cropRect.size.height * bounds.height
        )
        cropMaskLayer.path = UIBezierPath(rect: maskFrame).cgPath
        layer.mask = cropMaskLayer
        lastMaskCropRect = cropRect
        lastMaskBounds = bounds
    }
}
