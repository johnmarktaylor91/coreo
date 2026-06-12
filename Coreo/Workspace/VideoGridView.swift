// VideoGridView.swift
// Coreo
//
// Arranges video panels in a split-screen grid using LayoutEngine.
// Respects user layout overrides when present, falls back to the
// auto-calculated optimal layout. Panels that are outside their
// video's time range show an inactive overlay.

import AVFoundation
import SwiftUI

/// The split-screen video grid. Positions one VideoPanelView per video
/// using either LayoutEngine's calculated layout or the user's manual
/// panel overrides.
struct VideoGridView: View {
    /// Workspace view model that owns the players and project state.
    let viewModel: WorkspaceViewModel

    /// Playback controller that owns playhead state and players.
    let playback: PlaybackController

    /// Available container size passed in from the parent GeometryReader.
    let containerSize: CGSize

    @State private var expandedSyncIndex: Int?

    var body: some View {
        let rects = viewModel.panelRects(containerSize: containerSize)

        ZStack(alignment: .topLeading) {
            // Dark background visible in the gaps between panels.
            Color(red: 0.1, green: 0.1, blue: 0.1)

            ForEach(Array(viewModel.project.videos.enumerated()), id: \.element.id) { index, video in
                if index < rects.count, index < playback.players.count {
                    let rect = rects[index]
                    let cropRect = video.effectiveCropRect

                    ActiveVideoPanelView(
                        viewModel: viewModel,
                        playback: playback,
                        player: playback.players[index],
                        index: index,
                        cropRect: cropRect,
                        isMirrored: video.isMirrored,
                        isMuted: viewModel.isPanelMuted(index: index),
                        syncStatusLabel: viewModel.syncStatusLabel(for: index),
                        isReference: index == viewModel.project.referenceVideoIndex,
                        onNudgeSync: { delta in
                            viewModel.nudgeSyncOffset(index: index, deltaSeconds: delta)
                        },
                        onExpandSync: {
                            expandedSyncIndex = index
                        },
                        onToggleMute: {
                            viewModel.togglePanelMute(index: index)
                        },
                        onToggleMirror: {
                            viewModel.toggleMirror(index: index)
                        }
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
        .sheet(item: syncSheetBinding) { item in
            WaveformSyncNudgeView(
                viewModel: viewModel,
                videoIndex: item.index,
                onDone: { expandedSyncIndex = nil }
            )
        }
    }

    private var syncSheetBinding: Binding<SyncSheetItem?> {
        Binding(
            get: {
                guard let expandedSyncIndex else { return nil }
                return SyncSheetItem(index: expandedSyncIndex)
            },
            set: { item in
                expandedSyncIndex = item?.index
            }
        )
    }
}

/// Sheet identity for expanded sync editing.
private struct SyncSheetItem: Identifiable {
    /// Video display index.
    let index: Int

    /// Stable sheet identity.
    var id: Int { index }
}

/// Leaf panel wrapper that is allowed to read playhead state.
private struct ActiveVideoPanelView: View {
    /// Parent workspace model for timeline helpers.
    let viewModel: WorkspaceViewModel

    /// Playback controller that owns the ticking playhead.
    let playback: PlaybackController

    /// Player for this panel.
    let player: AVPlayer

    /// Video index.
    let index: Int

    /// Effective crop rectangle for the video.
    let cropRect: CGRect?

    /// Whether this angle is mirrored in preview.
    let isMirrored: Bool

    /// Whether this angle's preview audio is muted.
    let isMuted: Bool

    /// Compact sync status label.
    let syncStatusLabel: String

    /// Whether this panel is the sync reference.
    let isReference: Bool

    /// Sync nudge callback.
    let onNudgeSync: (Double) -> Void

    /// Expanded sync callback.
    let onExpandSync: () -> Void

    /// Toggle panel mute callback.
    let onToggleMute: () -> Void

    /// Toggle panel mirror callback.
    let onToggleMirror: () -> Void

    var body: some View {
        let currentTimeSeconds = playback.currentTimeSeconds
        VideoPanelView(
            player: player,
            cropRect: cropRect,
            isMirrored: isMirrored,
            isMuted: isMuted,
            isActive: viewModel.isVideoActive(index: index, at: currentTimeSeconds),
            inactiveLabel: viewModel.inactiveLabel(forIndex: index, at: currentTimeSeconds),
            syncStatusLabel: syncStatusLabel,
            isReference: isReference,
            onNudgeSync: onNudgeSync,
            onExpandSync: onExpandSync,
            onToggleMute: onToggleMute,
            onToggleMirror: onToggleMirror
        )
    }
}
