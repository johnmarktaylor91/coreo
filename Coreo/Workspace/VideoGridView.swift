// VideoGridView.swift
// Coreo
//
// Arranges video panels in a split-screen grid using LayoutEngine.
// Respects user layout overrides when present, falls back to the
// auto-calculated optimal layout. Panels that are outside their
// video's time range show an inactive overlay.

import SwiftUI

/// The split-screen video grid. Positions one VideoPanelView per video
/// using either LayoutEngine's calculated layout or the user's manual
/// panel overrides.
struct VideoGridView: View {
    /// Workspace view model that owns the players and project state.
    @ObservedObject var viewModel: WorkspaceViewModel

    /// Available container size passed in from the parent GeometryReader.
    let containerSize: CGSize

    var body: some View {
        let rects = panelRects

        ZStack(alignment: .topLeading) {
            // Dark background visible in the gaps between panels.
            Color(red: 0.1, green: 0.1, blue: 0.1)

            ForEach(Array(viewModel.project.videos.enumerated()), id: \.element.id) { index, _ in
                if index < rects.count, index < viewModel.players.count {
                    let rect = rects[index]
                    let isActive = viewModel.isVideoActive(
                        index: index,
                        at: viewModel.currentTimeSeconds
                    )
                    let label = viewModel.inactiveLabel(
                        forIndex: index,
                        at: viewModel.currentTimeSeconds
                    )
                    let cropRect = viewModel.project.cropOverrides?[index]

                    VideoPanelView(
                        player: viewModel.players[index],
                        cropRect: cropRect,
                        isActive: isActive,
                        inactiveLabel: label
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(
                        x: rect.midX,
                        y: rect.midY
                    )
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    // MARK: - Layout Calculation

    /// Returns panel rects, preferring user overrides when available.
    /// User overrides are stored as normalized (0-1) rects and scaled
    /// to the current container size.
    private var panelRects: [CGRect] {
        // Use manual layout overrides if the user has set them.
        if let overrides = viewModel.project.layoutOverrides {
            return overrides.panelRects.map { normalized in
                CGRect(
                    x: normalized.origin.x * containerSize.width,
                    y: normalized.origin.y * containerSize.height,
                    width: normalized.size.width * containerSize.width,
                    height: normalized.size.height * containerSize.height
                )
            }
        }

        // Auto-calculate using LayoutEngine.
        let aspectRatios: [CGFloat] = viewModel.project.videos.map { video in
            guard video.dimensions.height > 0 else { return 16.0 / 9.0 }
            return video.dimensions.width / video.dimensions.height
        }

        return LayoutEngine.calculateLayout(
            videoCount: viewModel.project.videos.count,
            aspectRatios: aspectRatios,
            containerSize: containerSize,
            gap: 4
        )
    }
}
