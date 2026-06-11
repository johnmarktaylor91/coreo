// ExportProgressView.swift
// Coreo
//
// Full-screen overlay shown during export. Displays a centered card with
// a circular progress ring, percentage text, and a cancel button. The dark
// semi-transparent backdrop prevents interaction with the workspace below.

import SwiftUI

/// Overlay view showing export progress with a circular indicator and cancel button.
///
/// Presented as a full-screen ZStack overlay. The card auto-updates as the
/// progress value changes. Cancel triggers the provided closure so the
/// caller can abort the AVAssetExportSession.
struct ExportProgressView: View {
    /// Export progress from 0.0 to 1.0.
    let progress: Double

    /// Called when the user taps Cancel.
    let onCancel: () -> Void

    /// Coral accent color.
    private let accentCoral = Color(red: 1.0, green: 0.42, blue: 0.21)

    /// Card width.
    private let cardWidth: CGFloat = 280

    var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Centered card
            VStack(spacing: 24) {
                // Title
                Text("Exporting...")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                // Progress ring
                ZStack {
                    // Background ring
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 6)
                        .frame(width: 80, height: 80)

                    // Progress ring
                    Circle()
                        .trim(from: 0, to: CGFloat(clampedProgress))
                        .stroke(
                            accentCoral,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)

                    // Percentage text
                    Text("\(percentageText)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }

                // Status text
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                // Cancel button
                Button {
                    Haptic.light()
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(minWidth: 88, minHeight: 44)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(CornerRadius.medium)
                }
                .buttonStyle(.coreo)
            }
            .padding(32)
            .frame(width: cardWidth)
            .background(Color(red: 0.1, green: 0.1, blue: 0.1))
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        }
    }

    // MARK: - Computed Properties

    /// Progress clamped to 0.0-1.0.
    private var clampedProgress: Double {
        min(max(progress, 0.0), 1.0)
    }

    /// Formatted percentage string (e.g., "47%").
    private var percentageText: String {
        "\(Int(clampedProgress * 100))%"
    }

    /// Descriptive status text based on progress stage.
    private var statusText: String {
        if clampedProgress < 0.05 {
            return "Preparing..."
        } else if clampedProgress < 0.20 {
            return "Loading videos..."
        } else if clampedProgress < 0.35 {
            return "Building composition..."
        } else if clampedProgress < 0.45 {
            return "Adding annotations..."
        } else if clampedProgress < 0.95 {
            return "Encoding video..."
        } else {
            return "Finalizing..."
        }
    }
}
