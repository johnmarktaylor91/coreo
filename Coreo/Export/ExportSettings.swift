// ExportSettings.swift
// Coreo
//
// Export resolution presets for portrait, landscape, and square outputs.

import Foundation

/// Available export aspect ratios.
enum ExportAspectRatio: String, CaseIterable, Identifiable {
    case landscape = "Landscape"
    case portrait = "Portrait"
    case square = "Square"

    var id: String { rawValue }

    /// Output resolution for each aspect ratio.
    var resolution: CGSize {
        switch self {
        case .landscape: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        }
    }

    /// SF Symbol for the picker.
    var iconName: String {
        switch self {
        case .landscape: "rectangle"
        case .portrait: "rectangle.portrait"
        case .square: "square"
        }
    }
}
