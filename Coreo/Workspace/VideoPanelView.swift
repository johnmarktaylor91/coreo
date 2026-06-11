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

    /// Accumulated pinch-to-zoom scale.
    @State private var currentScale: CGFloat = 1.0

    /// Scale from the in-progress magnification gesture.
    @State private var gestureScale: CGFloat = 1.0

    /// Pan offset for repositioning after zoom.
    @State private var panOffset: CGSize = .zero

    /// Offset from the in-progress drag gesture.
    @State private var gestureDragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
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

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = cropRect != nil ? .resizeAspectFill : .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        // Update player reference if it changed.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }

        // Update gravity based on crop presence.
        let gravity: AVLayerVideoGravity = cropRect != nil ? .resizeAspectFill : .resizeAspect
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }

        // Apply or remove crop mask.
        applyCropMask(to: uiView, crop: cropRect)
    }

    /// Applies a CALayer mask to simulate cropping to a normalized rect.
    private func applyCropMask(to view: PlayerUIView, crop: CGRect?) {
        guard let crop else {
            view.layer.mask = nil
            return
        }

        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let maskFrame = CGRect(
            x: crop.origin.x * bounds.width,
            y: crop.origin.y * bounds.height,
            width: crop.size.width * bounds.width,
            height: crop.size.height * bounds.height
        )

        let maskLayer = CAShapeLayer()
        maskLayer.path = UIBezierPath(rect: maskFrame).cgPath
        view.layer.mask = maskLayer
    }
}

// MARK: - PlayerUIView

/// A UIView subclass whose layer class is AVPlayerLayer, giving us direct
/// control over video rendering without an extra sublayer.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    /// Typed accessor for the backing AVPlayerLayer.
    var playerLayer: AVPlayerLayer {
        // Safe: layerClass guarantees the layer type.
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}
