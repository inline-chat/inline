#if os(iOS)
import SwiftUI

public struct AttachmentPickerRecentTile: View {
  private let item: AttachmentPickerModel.RecentItem
  private let isSelected: Bool
  private let onSelectToggle: () -> Void

  public init(
    item: AttachmentPickerModel.RecentItem,
    isSelected: Bool,
    onSelectToggle: @escaping () -> Void
  ) {
    self.item = item
    self.isSelected = isSelected
    self.onSelectToggle = onSelectToggle
  }

  public var body: some View {
    Button(action: onSelectToggle) {
      tileContent
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.mediaType == .video ? "Recent video" : "Recent photo")
    .accessibilityHint(isSelected ? "Double tap to deselect." : "Double tap to select.")
    .contextMenu {
      Button(isSelected ? "Deselect" : "Select", action: onSelectToggle)
    } preview: {
      AttachmentPickerRecentAssetPreview(item: item)
    }
  }

  private var tileContent: some View {
    AttachmentPickerAssetThumbnail(
      localIdentifier: item.localIdentifier,
      mediaType: item.mediaType
    )
    .frame(
      width: AttachmentPickerTileMetrics.thumbnailSide,
      height: AttachmentPickerTileMetrics.thumbnailSide
    )
    .overlay(alignment: .bottom) {
      if item.mediaType == .video {
        AttachmentPickerVideoBadgeOverlay(
          durationText: AttachmentPickerVideoDurationFormatter.string(for: item.duration)
        )
      }
    }
    .compositingGroup()
    .clipShape(.rect(cornerRadius: AttachmentPickerTileMetrics.cornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: AttachmentPickerTileMetrics.cornerRadius, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(isSelected ? 1 : 0), lineWidth: 3)
    }
    .overlay(alignment: .topTrailing) {
      AttachmentPickerSelectionCircle(isSelected: isSelected)
        .padding(8)
    }
    .contentShape(.rect(cornerRadius: AttachmentPickerTileMetrics.cornerRadius))
  }
}

private struct AttachmentPickerSelectionCircle: View {
  let isSelected: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(
          isSelected
            ? Color.accentColor
            : Color.black.opacity(0.28)
        )
      Circle()
        .stroke(
          isSelected ? Color.accentColor : .white.opacity(0.68),
          lineWidth: 1
        )

      if isSelected {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white)
      }
    }
    .frame(
      width: AttachmentPickerTileMetrics.selectionIndicatorSize,
      height: AttachmentPickerTileMetrics.selectionIndicatorSize
    )
  }
}

private struct AttachmentPickerVideoBadgeOverlay: View {
  let durationText: String?

  var body: some View {
    ZStack(alignment: .bottom) {
      LinearGradient(
        colors: [.clear, .black.opacity(0.84)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: AttachmentPickerTileMetrics.videoBadgeSpacing) {
        Image(systemName: "video.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white)

        Spacer(minLength: 0)

        if let durationText {
          Text(durationText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
      }
      .padding(.horizontal, AttachmentPickerTileMetrics.videoBadgeHorizontalInset)
      .frame(height: AttachmentPickerTileMetrics.videoBadgeHeight, alignment: .bottom)
      .padding(.bottom, AttachmentPickerTileMetrics.videoBadgeBottomInset)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: AttachmentPickerTileMetrics.verticalPreviewScrimHeight,
      maxHeight: AttachmentPickerTileMetrics.verticalPreviewScrimHeight,
      alignment: .bottom
    )
    .allowsHitTesting(false)
    .clipped()
  }
}
#endif
