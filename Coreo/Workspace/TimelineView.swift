// TimelineView.swift
// Coreo
//
// The unified timeline scrub bar at the bottom of the workspace. Shows video
// coverage bars, speed segment overlays, a draggable playhead, annotation
// markers, and optional trim indicators. All video panels are driven by the
// single shared timeline this view controls.

import SwiftUI

/// The main timeline scrub bar displayed at the bottom of the workspace.
///
/// Visual stack (top to bottom within `height`):
/// 1. Video coverage bars (~12pt) — colored per-video temporal coverage
/// 2. Speed segment overlays (~4pt) — orange/red/green speed indicators
/// 3. Main scrub area (~40pt) — dark background with draggable playhead
/// 4. Annotation markers (~12pt) — colored dots at annotation start times
/// 5. Trim brackets — dim out-of-range regions when trim is active
struct TimelineView: View {
    /// The workspace view model driving playback and project state.
    @ObservedObject var viewModel: WorkspaceViewModel

    /// Total height of the timeline bar.
    let height: CGFloat = 80

    /// Whether the user is currently dragging the playhead.
    @State private var isDragging: Bool = false

    /// Stashed playback state so we can resume after a drag.
    @State private var wasPlayingBeforeDrag: Bool = false

    /// One color per video track, cycling through the palette.
    private let coverageColors: [Color] = [.blue, .green, .purple, .orange, .pink, .teal]

    /// The app's coral accent color.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Dark panel background matching the workspace theme.
    private let panelBackground = Color(red: 0.1, green: 0.1, blue: 0.1)

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                // Background
                panelBackground
                    .cornerRadius(8)

                VStack(spacing: 0) {
                    // 1. Video coverage bars
                    videoCoverageBars(width: width)
                        .frame(height: 12)

                    // 2. Speed segment overlays
                    speedSegmentOverlays(width: width)
                        .frame(height: 4)

                    // 3. Main scrub area with playhead
                    scrubArea(width: width)
                        .frame(height: 40)

                    // Time labels
                    timeLabels(width: width)
                        .frame(height: 12)

                    // 4. Annotation markers
                    AnnotationMarkerView(
                        annotations: viewModel.project.annotations,
                        timelineStart: timelineStart,
                        timelineDuration: timelineDuration,
                        onTapAnnotation: { annotation in
                            viewModel.seek(to: annotation.startTimeSeconds)
                            viewModel.enterAnnotationMode()
                        }
                    )
                    .frame(height: 12)
                }
                .padding(.horizontal, 8)

                // 5. Trim overlay (dimmed regions)
                trimOverlay(width: width)
            }
            .gesture(scrubDragGesture(width: width))
        }
        .frame(height: height)
    }

    // MARK: - Timeline Math

    /// The earliest point on the timeline.
    private var timelineStart: Double {
        viewModel.project.timelineStartSeconds
    }

    /// The latest point on the timeline.
    private var timelineEnd: Double {
        viewModel.project.timelineEndSeconds
    }

    /// Total span of the timeline.
    private var timelineDuration: Double {
        viewModel.project.timelineDurationSeconds
    }

    /// Converts a timeline position in seconds to an x-coordinate.
    ///
    /// - Parameters:
    ///   - seconds: The timeline position.
    ///   - width: The available drawing width (after horizontal padding).
    /// - Returns: The x-coordinate within the scrub area.
    private func xPosition(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard timelineDuration > 0 else { return 0 }
        let fraction = (seconds - timelineStart) / timelineDuration
        return CGFloat(fraction) * width
    }

    /// Converts an x-coordinate to a timeline position in seconds.
    ///
    /// - Parameters:
    ///   - xPosition: The x-coordinate within the scrub area.
    ///   - width: The available drawing width (after horizontal padding).
    /// - Returns: The timeline position in seconds, clamped to bounds.
    private func seconds(for xPosition: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return timelineStart }
        let fraction = Double(xPosition / width)
        let clamped = min(max(fraction, 0), 1)
        return timelineStart + clamped * timelineDuration
    }

    // MARK: - Video Coverage Bars

    /// Renders one thin colored bar per video showing its temporal coverage.
    @ViewBuilder
    private func videoCoverageBars(width: CGFloat) -> some View {
        let usableWidth = width
        ZStack(alignment: .leading) {
            Color.clear

            ForEach(Array(viewModel.project.videos.enumerated()), id: \.offset) { index, video in
                let offset = index < viewModel.project.syncOffsets.count
                    ? viewModel.project.syncOffsets[index]
                    : 0
                let videoStart = offset
                let videoEnd = offset + video.durationSeconds

                let x = xPosition(for: videoStart, in: usableWidth)
                let endX = xPosition(for: videoEnd, in: usableWidth)
                let barWidth = max(endX - x, 1)

                let color = coverageColors[index % coverageColors.count]

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: 3)
                    .offset(x: x, y: CGFloat(index) * 3.5)
            }
        }
    }

    // MARK: - Speed Segment Overlays

    /// Colored overlays indicating speed modifications on the timeline.
    @ViewBuilder
    private func speedSegmentOverlays(width: CGFloat) -> some View {
        let usableWidth = width
        ZStack(alignment: .leading) {
            Color.clear

            ForEach(viewModel.project.speedSegments) { segment in
                let x = xPosition(for: segment.startTimeSeconds, in: usableWidth)
                let endX = xPosition(for: segment.startTimeSeconds + segment.durationSeconds, in: usableWidth)
                let segWidth = max(endX - x, 1)

                let color = speedSegmentColor(for: segment)

                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(0.6))
                    .frame(width: segWidth, height: 4)
                    .offset(x: x)
            }
        }
    }

    /// Maps a speed segment to its display color.
    ///
    /// - Parameter segment: The speed segment.
    /// - Returns: Orange for slow-mo, red for holds, green for fast.
    private func speedSegmentColor(for segment: SpeedSegment) -> Color {
        if segment.isHold {
            return .red
        } else if segment.rate < 1.0 {
            return .orange
        } else {
            return .green
        }
    }

    // MARK: - Scrub Area

    /// The main draggable timeline area with the playhead.
    @ViewBuilder
    private func scrubArea(width: CGFloat) -> some View {
        let usableWidth = width
        ZStack(alignment: .leading) {
            // Background track
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.4))

            // Played region
            let playheadX = xPosition(for: viewModel.currentTimeSeconds, in: usableWidth)
            RoundedRectangle(cornerRadius: 4)
                .fill(accentCoral.opacity(0.15))
                .frame(width: max(playheadX, 0))

            // Playhead line
            playheadView(at: playheadX)
        }
    }

    /// The playhead indicator: a thin white vertical line with a circle handle.
    @ViewBuilder
    private func playheadView(at x: CGFloat) -> some View {
        ZStack(alignment: .top) {
            // Vertical line
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: 40)

            // Circle handle at top
            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                .offset(y: -4)
        }
        .offset(x: x - 1)
    }

    // MARK: - Time Labels

    /// Current time and total duration labels flanking the scrub area.
    @ViewBuilder
    private func timeLabels(width: CGFloat) -> some View {
        HStack {
            Text(TimeFormatting.format(viewModel.currentTimeSeconds))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            Text(TimeFormatting.format(timelineEnd))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Trim Overlay

    /// Dims the timeline regions outside the user's trim range.
    @ViewBuilder
    private func trimOverlay(width: CGFloat) -> some View {
        if let trimStart = viewModel.project.timelineTrimStartSeconds,
           let trimDuration = viewModel.project.timelineTrimDurationSeconds {
            let usableWidth = width - 16 // account for horizontal padding
            let trimEnd = trimStart + trimDuration

            let leftEdge = xPosition(for: trimStart, in: usableWidth) + 8
            let rightEdge = xPosition(for: trimEnd, in: usableWidth) + 8

            // Left dimmed region
            if leftEdge > 8 {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: leftEdge - 8, height: height)
                    .offset(x: 8)
                    .allowsHitTesting(false)

                // Left bracket
                Rectangle()
                    .fill(accentCoral)
                    .frame(width: 2, height: height)
                    .offset(x: leftEdge)
                    .allowsHitTesting(false)
            }

            // Right dimmed region
            if rightEdge < usableWidth + 8 {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: (usableWidth + 8) - rightEdge, height: height)
                    .offset(x: rightEdge)
                    .allowsHitTesting(false)

                // Right bracket
                Rectangle()
                    .fill(accentCoral)
                    .frame(width: 2, height: height)
                    .offset(x: rightEdge)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Drag Gesture

    /// Creates the drag gesture for scrubbing the playhead.
    private func scrubDragGesture(width: CGFloat) -> some Gesture {
        let usableWidth = width - 16 // horizontal padding
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    Haptic.light()
                    wasPlayingBeforeDrag = viewModel.isPlaying
                    if viewModel.isPlaying {
                        viewModel.togglePlayback()
                    }
                }
                let xInPadded = value.location.x - 8
                let time = seconds(for: xInPadded, in: usableWidth)
                viewModel.seek(to: time)
            }
            .onEnded { _ in
                isDragging = false
                if wasPlayingBeforeDrag && !viewModel.isPlaying {
                    viewModel.togglePlayback()
                }
                wasPlayingBeforeDrag = false
            }
    }
}
