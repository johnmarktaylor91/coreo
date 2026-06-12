// ShareSheetView.swift
// Coreo
//
// UIActivityViewController wrapper for presenting the iOS share sheet
// after a successful export. Accepts any mix of activity items (typically
// a file URL to the exported .mp4).

import SwiftUI

/// UIActivityViewController wrapper for sharing exported videos.
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showShareSheet) {
///     ShareSheetView(activityItems: [exportedVideoURL])
/// }
/// ```
struct ShareSheetView: UIViewControllerRepresentable {
    /// Items to share (typically a URL to the exported .mp4 file).
    let activityItems: [Any]

    /// Optional list of excluded activity types.
    var excludedActivityTypes: [UIActivity.ActivityType]?

    /// Creates and configures the UIActivityViewController.
    ///
    /// - Parameter context: The representable context.
    /// - Returns: A configured UIActivityViewController.
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    /// No-op: the activity view controller doesn't need updates.
    ///
    /// - Parameters:
    ///   - uiViewController: The existing controller.
    ///   - context: The representable context.
    func updateUIViewController(
        _: UIActivityViewController,
        context _: Context
    ) {
        // Nothing to update after presentation.
    }
}
