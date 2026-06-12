// AnnotationTimeRangeControl.swift
// Coreo
//
// Mini timeline control for adjusting an annotation's visible time range.
// Shows a horizontal bar representing the full timeline, a highlighted range
// segment with draggable handles, and a "Show always" toggle. Compact at
// ~50pt height for use below the main timeline or in a popover.

import SwiftUI

/// A compact control for editing an annotation's visible time range on the timeline.
///
/// Displays a thin bar for the full timeline, a highlighted segment for the
/// annotation's window, two draggable handle circles, a "Show always" toggle,
/// and a text label showing the current range.
struct AnnotationTimeRangeControl: View {
    /// The annotation's start time in seconds (two-way binding).
    @Binding var startTimeSeconds: Double

    /// The annotation's visible duration in seconds (two-way binding).
    @Binding var durationSeconds: Double

    /// Whether the annotation is persistent (visible for the entire timeline).
    @Binding var isPersistent: Bool

    /// The earliest point on the project timeline.
    let timelineStart: Double

    /// The latest point on the project timeline.
    let timelineEnd: Double

    /// Tracks whether the start handle is being dragged.
    @State private var isDraggingStart: Bool = false

    /// Tracks whether the end handle is being dragged.
    @State private var isDraggingEnd: Bool = false

    /// The app's coral accent color.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// The semi-transparent dark background for the control.
    private let controlBackground = Color(red: 0.1, green: 0.1, blue: 0.1)

    /// Handle circle diameter.
    private let handleSize: CGFloat = 14

    /// The minimum allowed annotation duration in seconds.
    private let minimumDuration: Double = 0.1

    /// The timeline's total span.
    private var timelineDuration: Double {
        max(timelineEnd - timelineStart, 0.001)
    }

    /// The annotation's end time in seconds.
    private var endTimeSeconds: Double {
        startTimeSeconds + durationSeconds
    }

    var body: some View {
        VStack(spacing: 6) {
            // Range bar with handles
            GeometryReader { geometry in
                let width = geometry.size.width
                rangeBar(width: width)
            }
            .frame(height: 20)

            // Bottom row: toggle + time label
            HStack {
                Toggle(isOn: $isPersistent) {
                    Text("Show always")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .toggleStyle(CompactToggleStyle())
                .onChange(of: isPersistent) { _, newValue in
                    if newValue {
                        startTimeSeconds = timelineStart
                        durationSeconds = timelineDuration
                    }
                }

                Spacer()

                Text("Visible: \(TimeFormatting.format(startTimeSeconds)) \u{2013} \(TimeFormatting.format(endTimeSeconds))")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(controlBackground)
        )
        .frame(height: 50)
    }

    // MARK: - Range Bar

    /// The horizontal bar showing the full timeline with a highlighted annotation range.
    ///
    /// - Parameter width: Available width for the bar.
    private func rangeBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Full timeline track
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.1))
                .frame(height: 4)

            // Highlighted range segment
            let startX = xPosition(for: startTimeSeconds, in: width)
            let endX = xPosition(for: endTimeSeconds, in: width)
            let segmentWidth = max(endX - startX, 2)

            RoundedRectangle(cornerRadius: 2)
                .fill(isPersistent ? accentCoral.opacity(0.5) : accentCoral)
                .frame(width: segmentWidth, height: 4)
                .offset(x: startX)

            // Start handle
            if !isPersistent {
                handleCircle(at: startX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingStart = true
                                let newStart = seconds(for: value.location.x, in: width)
                                let maxStart = endTimeSeconds - minimumDuration
                                let clamped = min(max(newStart, timelineStart), maxStart)
                                let newDuration = endTimeSeconds - clamped
                                startTimeSeconds = clamped
                                durationSeconds = newDuration
                            }
                            .onEnded { _ in
                                isDraggingStart = false
                            }
                    )
            }

            // End handle
            if !isPersistent {
                handleCircle(at: endX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingEnd = true
                                let newEnd = seconds(for: value.location.x, in: width)
                                let minEnd = startTimeSeconds + minimumDuration
                                let clamped = min(max(newEnd, minEnd), timelineEnd)
                                durationSeconds = clamped - startTimeSeconds
                            }
                            .onEnded { _ in
                                isDraggingEnd = false
                            }
                    )
            }
        }
    }

    /// A small circle used as a drag handle on the range bar.
    ///
    /// - Parameter x: The x-offset for the handle.
    /// - Returns: A styled circle view positioned at the given offset.
    private func handleCircle(at x: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            .offset(x: x - handleSize / 2)
    }

    // MARK: - Coordinate Conversion

    /// Converts seconds to an x-coordinate within the range bar.
    private func xPosition(for seconds: Double, in width: CGFloat) -> CGFloat {
        guard timelineDuration > 0 else { return 0 }
        let fraction = (seconds - timelineStart) / timelineDuration
        return CGFloat(fraction) * width
    }

    /// Converts an x-coordinate to seconds on the timeline.
    private func seconds(for x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return timelineStart }
        let fraction = Double(x / width)
        let clamped = min(max(fraction, 0), 1)
        return timelineStart + clamped * timelineDuration
    }
}

// MARK: - Compact Toggle Style

/// A small-scale toggle style matching the app's dark theme and coral accent.
struct CompactToggleStyle: ToggleStyle {
    /// The app's coral accent color.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label

            RoundedRectangle(cornerRadius: 8)
                .fill(configuration.isOn ? accentCoral : Color.white.opacity(0.2))
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}
