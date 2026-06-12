// SpeedControlView.swift
// Coreo
//
// UI for selecting timeline ranges and assigning speed/hold values.
// When activated, the timeline enters "segment selection" mode: drag to
// select a range, or tap for a single-point hold. After selection, a
// speed picker popup lets the user assign a rate or hold duration. Existing
// speed segments are rendered as colored overlays on the timeline.

import SwiftUI

/// Panel for creating and managing speed/hold segments on the timeline.
///
/// Integrates into the workspace edit tools. Provides:
/// - Drag-to-select range mode with coral highlight
/// - Tap-to-hold mode for single-frame freezes
/// - Speed picker popup with common rate presets
/// - Hold duration picker for freeze frames
/// - Visual overlay of existing segments (orange = slow, red = hold, green = fast)
struct SpeedControlView: View {
    /// The workspace view model owning the project and timeline state.
    let viewModel: WorkspaceViewModel

    /// Playback controller for mini-timeline playhead and seeking.
    let playback: PlaybackController

    /// Whether the user is currently dragging to select a range.
    @State private var isSelectingRange: Bool = false

    /// Start of the user's drag selection in timeline seconds.
    @State private var rangeStart: Double = 0

    /// End of the user's drag selection in timeline seconds.
    @State private var rangeEnd: Double = 0

    /// Whether the speed picker popup is visible.
    @State private var showSpeedPicker: Bool = false

    /// Whether the current selection is a single-point tap (for holds).
    @State private var isTapSelection: Bool = false

    /// The segment currently being edited (for removal).
    @State private var editingSegmentID: UUID?

    /// Minimum drag distance (in seconds) to distinguish a range from a tap.
    private let tapThreshold: Double = 0.15

    /// Coral accent used throughout the app.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Available speed rate presets.
    private let speedOptions: [(label: String, rate: Float)] = [
        ("0.25x", 0.25),
        ("0.5x", 0.5),
        ("0.75x", 0.75),
        ("1x", 1.0),
        ("1.5x", 1.5),
        ("2x", 2.0)
    ]

    /// Available hold duration presets.
    private let holdOptions: [(label: String, duration: Double)] = [
        ("Hold 1s", 1.0),
        ("Hold 2s", 2.0),
        ("Hold 3s", 3.0),
        ("Hold 5s", 5.0)
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "speedometer")
                    .foregroundColor(accentCoral)
                Text("Speed & Holds")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }

            // Timeline selection area
            selectionTimeline

            // Existing segments list
            if !viewModel.project.speedSegments.isEmpty {
                existingSegmentsList
            }

            // Instructions
            if !showSpeedPicker {
                Text("Drag on the timeline to select a range, or tap for a hold point")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(Color(red: 0.1, green: 0.1, blue: 0.1))
        .cornerRadius(12)
        .overlay {
            if showSpeedPicker {
                speedPickerPopup
            }
        }
    }

    // MARK: - Selection Timeline

    /// A miniature timeline strip where the user drags to select speed ranges.
    private var selectionTimeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.4))

                // Existing speed segments
                existingSegmentOverlays(width: width)

                // Selection highlight
                if isSelectingRange || showSpeedPicker {
                    selectionHighlight(width: width)
                }

                // Hold markers
                HoldMarkerView(
                    holdSegments: viewModel.project.speedSegments.filter(\.isHold),
                    timelineStart: viewModel.project.timelineStartSeconds,
                    timelineDuration: viewModel.project.timelineDurationSeconds
                )

                // Playhead indicator
                let playheadX = xPosition(
                    for: playback.currentTimeSeconds,
                    in: width
                )
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1.5, height: 36)
                    .offset(x: playheadX - 0.75)
            }
            .gesture(rangeSelectionGesture(width: width))
        }
        .frame(height: 36)
    }

    // MARK: - Existing Segment Overlays

    /// Renders colored overlays for each existing speed segment on the timeline strip.
    private func existingSegmentOverlays(width: CGFloat) -> some View {
        ForEach(viewModel.project.speedSegments) { segment in
            let startX = xPosition(for: segment.startTimeSeconds, in: width)
            let endX = xPosition(for: segment.endTimeSeconds, in: width)
            let segWidth = max(endX - startX, 2)

            RoundedRectangle(cornerRadius: 2)
                .fill(colorForSegment(segment).opacity(0.35))
                .frame(width: segWidth, height: 36)
                .offset(x: startX)
                .allowsHitTesting(false)
        }
    }

    /// Selection highlight in semi-transparent coral.
    @ViewBuilder
    private func selectionHighlight(width: CGFloat) -> some View {
        let startX = xPosition(for: min(rangeStart, rangeEnd), in: width)
        let endX = xPosition(for: max(rangeStart, rangeEnd), in: width)
        let highlightWidth = max(endX - startX, 2)

        RoundedRectangle(cornerRadius: 2)
            .fill(accentCoral.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(accentCoral.opacity(0.7), lineWidth: 1)
            )
            .frame(width: highlightWidth, height: 36)
            .offset(x: startX)
            .allowsHitTesting(false)
    }

    // MARK: - Speed Picker Popup

    /// The popup shown after a range selection, offering speed/hold options.
    private var speedPickerPopup: some View {
        VStack(spacing: 12) {
            // Title
            Text(isTapSelection ? "Add Hold" : "Set Speed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            if isTapSelection {
                // Hold duration options
                HStack(spacing: 8) {
                    ForEach(holdOptions, id: \.duration) { option in
                        Button {
                            addHoldSegment(duration: option.duration)
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.3))
                                .cornerRadius(6)
                        }
                    }
                }
            } else {
                // Speed options
                HStack(spacing: 6) {
                    ForEach(speedOptions, id: \.rate) { option in
                        Button {
                            addSpeedSegment(rate: option.rate)
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    colorForRate(option.rate).opacity(0.3)
                                )
                                .cornerRadius(6)
                        }
                    }
                }
            }

            // Remove button (if editing an existing segment)
            if let segmentID = editingSegmentID {
                Button {
                    removeSegment(id: segmentID)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Remove")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                }
            }

            // Cancel button
            Button {
                dismissPicker()
            } label: {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
    }

    // MARK: - Existing Segments List

    /// Compact list of existing speed segments with edit/delete controls.
    private var existingSegmentsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Segments")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sortedSegments) { segment in
                        segmentChip(segment)
                    }
                }
            }
        }
    }

    /// A compact chip representing a single speed segment.
    private func segmentChip(_ segment: SpeedSegment) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForSegment(segment))
                .frame(width: 6, height: 6)

            if segment.isHold {
                let holdDur = segment.holdDurationSeconds ?? 1.0
                Text("Hold \(Int(holdDur))s")
                    .font(.system(size: 10, weight: .medium))
            } else {
                Text("\(String(format: "%.2g", segment.rate))x")
                    .font(.system(size: 10, weight: .medium))
            }

            Text("@ \(TimeFormatting.formatShort(segment.startTimeSeconds))")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))

            Button {
                var map = SpeedMap(segments: viewModel.project.speedSegments)
                map.removeSegment(id: segment.id)
                viewModel.project.speedSegments = map.segments
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(colorForSegment(segment).opacity(0.2))
        .cornerRadius(8)
        .onTapGesture {
            // Tap a chip to seek to that segment's position
            viewModel.seek(to: segment.startTimeSeconds)
        }
    }

    // MARK: - Gesture

    /// Drag gesture for selecting a range on the mini-timeline.
    private func rangeSelectionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isSelectingRange {
                    isSelectingRange = true
                    showSpeedPicker = false
                    editingSegmentID = nil
                    rangeStart = seconds(for: value.startLocation.x, in: width)
                }
                rangeEnd = seconds(for: value.location.x, in: width)
            }
            .onEnded { _ in
                isSelectingRange = false

                // Determine if this was a tap or a drag
                let distance = abs(rangeEnd - rangeStart)
                if distance < tapThreshold {
                    // Tap: set up for hold placement
                    isTapSelection = true
                    rangeEnd = rangeStart
                } else {
                    // Drag: set up for speed assignment
                    isTapSelection = false
                    // Normalize so start < end
                    if rangeStart > rangeEnd {
                        let temp = rangeStart
                        rangeStart = rangeEnd
                        rangeEnd = temp
                    }
                }

                // Check if tapping on an existing segment
                let tapCenter = (rangeStart + rangeEnd) / 2.0
                if let existing = viewModel.project.speedSegments.first(where: {
                    tapCenter >= $0.startTimeSeconds && tapCenter < $0.endTimeSeconds
                }) {
                    editingSegmentID = existing.id
                }

                showSpeedPicker = true
            }
    }

    // MARK: - Actions

    /// Adds a speed segment for the selected range.
    ///
    /// - Parameter rate: The playback rate to assign to the segment.
    private func addSpeedSegment(rate: Float) {
        let segment = SpeedSegment(
            id: UUID(),
            startTimeSeconds: min(rangeStart, rangeEnd),
            durationSeconds: abs(rangeEnd - rangeStart),
            rate: rate,
            holdDurationSeconds: nil
        )
        var map = SpeedMap(segments: viewModel.project.speedSegments)
        map.addSegment(segment)
        viewModel.project.speedSegments = map.segments
        dismissPicker()
    }

    /// Adds a hold (freeze-frame) segment at the selected point.
    ///
    /// - Parameter duration: How long the frame should be held.
    private func addHoldSegment(duration: Double) {
        // Hold segments have zero rate and a tiny timeline footprint
        // (the hold duration is stored separately and applied during export).
        let segment = SpeedSegment(
            id: UUID(),
            startTimeSeconds: rangeStart,
            durationSeconds: 0.01, // minimal footprint on the timeline
            rate: 0.0,
            holdDurationSeconds: duration
        )
        var map = SpeedMap(segments: viewModel.project.speedSegments)
        map.addSegment(segment)
        viewModel.project.speedSegments = map.segments
        dismissPicker()
    }

    /// Removes the segment with the given ID.
    ///
    /// - Parameter id: The segment's unique identifier.
    private func removeSegment(id: UUID) {
        var map = SpeedMap(segments: viewModel.project.speedSegments)
        map.removeSegment(id: id)
        viewModel.project.speedSegments = map.segments
        dismissPicker()
    }

    /// Hides the speed picker and clears selection state.
    private func dismissPicker() {
        showSpeedPicker = false
        editingSegmentID = nil
        isTapSelection = false
    }

    // MARK: - Timeline Math

    /// All segments sorted by start time.
    private var sortedSegments: [SpeedSegment] {
        viewModel.project.speedSegments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
    }

    /// Converts a timeline position to an x-coordinate.
    ///
    /// - Parameters:
    ///   - seconds: Timeline position.
    ///   - width: Available drawing width.
    /// - Returns: The x-coordinate.
    private func xPosition(for seconds: Double, in width: CGFloat) -> CGFloat {
        let duration = viewModel.project.timelineDurationSeconds
        guard duration > 0 else { return 0 }
        let start = viewModel.project.timelineStartSeconds
        let fraction = (seconds - start) / duration
        return CGFloat(fraction) * width
    }

    /// Converts an x-coordinate to a timeline position, clamped to bounds.
    ///
    /// - Parameters:
    ///   - xPosition: The x-coordinate.
    ///   - width: Available drawing width.
    /// - Returns: Timeline position in seconds.
    private func seconds(for xPosition: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return viewModel.project.timelineStartSeconds }
        let fraction = Double(xPosition / width)
        let clamped = min(max(fraction, 0), 1)
        let start = viewModel.project.timelineStartSeconds
        let duration = viewModel.project.timelineDurationSeconds
        return start + clamped * duration
    }

    // MARK: - Color Helpers

    /// Returns the display color for a speed segment.
    ///
    /// - Parameter segment: The speed segment.
    /// - Returns: Red for holds, orange for slow-mo, green for fast, gray for 1x.
    private func colorForSegment(_ segment: SpeedSegment) -> Color {
        if segment.isHold { return .red }
        return colorForRate(segment.rate)
    }

    /// Returns the display color for a given rate value.
    ///
    /// - Parameter rate: Playback rate multiplier.
    /// - Returns: Orange for < 1.0, green for > 1.0, gray for 1.0.
    private func colorForRate(_ rate: Float) -> Color {
        if rate < 1.0 { return .orange }
        if rate > 1.0 { return .green }
        return .gray
    }
}
