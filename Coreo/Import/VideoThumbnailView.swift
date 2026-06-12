// VideoThumbnailView.swift
// Coreo
//
// Individual video thumbnail tile for the horizontal import row.
// Shows a frame preview, filename, duration, and a remove button.

import SwiftUI
import UIKit

/// Displays a single video's thumbnail, filename, and duration in
/// the import screen's horizontal scroll row.
struct VideoThumbnailView: View {
    /// The video asset to display.
    let video: VideoAsset

    /// Called when the user taps the remove button.
    let onRemove: () -> Void

    /// Width of the thumbnail tile.
    private let tileWidth: CGFloat = 80

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailImage
                    .frame(width: tileWidth, height: thumbnailHeight)
                    .clipped()
                    .cornerRadius(8)

                removeButton
            }

            Text(video.originalFilename)
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: tileWidth)

            Text(video.formattedDuration)
                .font(.system(size: 9))
                .foregroundColor(Color.white.opacity(0.5))
        }
    }

    // MARK: - Subviews

    /// The video frame image, or a placeholder if no thumbnail data exists.
    @ViewBuilder
    private var thumbnailImage: some View {
        if let data = video.thumbnailData,
           let uiImage = UIImage(data: data)
        {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color(white: 0.15))
                .overlay(
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundColor(Color(white: 0.4))
                )
        }
    }

    /// Small "x" button in the top-right corner of the thumbnail.
    /// Visual is 20pt but hit target extends to 44pt for accessibility.
    private var removeButton: some View {
        Button {
            Haptic.light()
            onRemove()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(.coreoToolbar)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .offset(x: 12, y: -12)
    }

    // MARK: - Layout

    /// Computes the thumbnail height based on the video's aspect ratio,
    /// falling back to a 16:9 default.
    private var thumbnailHeight: CGFloat {
        guard video.dimensions.width > 0 else {
            return tileWidth * (9.0 / 16.0)
        }
        let aspectRatio = video.dimensions.height / video.dimensions.width
        let height = tileWidth * aspectRatio
        // Clamp to a reasonable range
        return min(max(height, 45), 120)
    }
}
