// DocumentPickerView.swift
// Coreo
//
// UIViewControllerRepresentable wrapper around UIDocumentPickerViewController
// for importing videos from the Files app.

import SwiftUI
import UniformTypeIdentifiers

/// Wraps UIDocumentPickerViewController to let users import video files
/// from the Files app or other document providers.
struct DocumentPickerView: UIViewControllerRepresentable {
    /// Called with the URLs of all selected files when the user confirms.
    var onPick: ([URL]) -> Void

    /// Supported video content types for the picker.
    private static let supportedTypes: [UTType] = [
        .movie,
        .mpeg4Movie,
        .quickTimeMovie
    ]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.supportedTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _: UIDocumentPickerViewController,
        context _: Context
    ) {
        // No dynamic updates needed.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    // MARK: - Coordinator

    /// Bridges UIDocumentPickerDelegate callbacks to the SwiftUI closure.
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onPick(urls)
        }

        func documentPickerWasCancelled(
            _: UIDocumentPickerViewController
        ) {
            // User cancelled -- nothing to do.
        }
    }
}
