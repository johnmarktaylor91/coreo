// ExportCoordinator.swift
// Coreo
//
// Observable export state and task coordination for the workspace.

import Foundation
import Observation
import SwiftUI

/// Coordinates export progress, cancellation, completion, and share state.
@MainActor
@Observable
final class ExportCoordinator {
    /// True while an export operation is in progress.
    var isExporting: Bool = false

    /// 0.0-1.0 progress of an active export.
    var exportProgress: Double = 0.0

    /// URL of the last exported video, triggers the share sheet.
    var exportedVideoURL: URL?

    /// True when the share sheet should be presented.
    var showShareSheet: Bool = false

    /// Error message from a failed export, shown as an alert.
    var exportError: String?

    /// Selected export aspect ratio.
    var exportAspectRatio: ExportAspectRatio = .landscape

    /// The active export task, kept so it can be cancelled.
    private var exportTask: Task<Void, Never>?

    /// Export resolution based on selected aspect ratio.
    var exportResolution: CGSize {
        exportAspectRatio.resolution
    }

    /// Starts the export pipeline. Shows progress overlay, then share sheet on success.
    ///
    /// - Parameters:
    ///   - project: Project snapshot to export.
    ///   - pausePlayback: Callback that pauses active playback before export starts.
    func startExport(project: CoreoProject, pausePlayback: @escaping () -> Void) {
        guard !isExporting else { return }
        pausePlayback()

        isExporting = true
        exportProgress = 0.0
        exportError = nil

        exportTask = Task {
            do {
                let resolution = await MainActor.run { self.exportResolution }
                let url = try await ExportEngine.export(
                    project: project,
                    resolution: resolution,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            self?.exportProgress = progress
                        }
                    }
                )
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    isExporting = false
                    exportTask = nil
                    return
                }
                Haptic.success()
                exportedVideoURL = url
                isExporting = false
                showShareSheet = true
                exportTask = nil
            } catch is CancellationError {
                isExporting = false
                exportTask = nil
            } catch let error as ExportError where error == .cancelled {
                isExporting = false
                exportTask = nil
            } catch {
                Haptic.error()
                exportError = error.localizedDescription
                isExporting = false
                exportTask = nil
            }
        }
    }

    /// Cancels an in-progress export.
    func cancelExport() {
        exportTask?.cancel()
        isExporting = false
        showShareSheet = false
    }

    /// Cleans up the exported temp file after the share sheet is dismissed.
    func cleanUpExportedFile() {
        if let url = exportedVideoURL {
            try? FileManager.default.removeItem(at: url)
            exportedVideoURL = nil
        }
    }

    /// Cancels any active export task during workspace teardown.
    func tearDown() {
        exportTask?.cancel()
    }
}

private extension ExportError {
    /// Compares export errors used by cancellation handling.
    ///
    /// - Parameters:
    ///   - lhs: Left error.
    ///   - rhs: Right error.
    /// - Returns: True for matching cancellation errors.
    static func == (lhs: ExportError, rhs: ExportError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled): true
        default: false
        }
    }
}
