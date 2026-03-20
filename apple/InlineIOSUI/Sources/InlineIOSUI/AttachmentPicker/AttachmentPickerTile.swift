#if os(iOS)
import Photos
import SwiftUI
import UIKit

enum AttachmentPickerTileMetrics {
  static let thumbnailWidth: CGFloat = 110
  static let thumbnailHeight: CGFloat = 110
  static let cornerRadius: CGFloat = 18
}

public struct AttachmentPickerCameraTile: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    AttachmentPickerActionTile(
      title: "Camera",
      systemImage: "camera",
      action: action
    )
    .accessibilityLabel("Camera")
  }
}

public struct AttachmentPickerPhotosTile: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    AttachmentPickerActionTile(
      title: "Photos",
      systemImage: "photo.on.rectangle.angled",
      action: action
    )
    .accessibilityLabel("Photos")
  }
}

private struct AttachmentPickerActionTile: View {
  private let title: String
  private let systemImage: String
  private let action: () -> Void

  init(title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: systemImage)
          .foregroundStyle(.primary)

        Text(title)
          .foregroundStyle(.primary)
      }
      .frame(
        width: AttachmentPickerTileMetrics.thumbnailWidth,
        height: AttachmentPickerTileMetrics.thumbnailHeight
      )
      .background(
        RoundedRectangle(cornerRadius: AttachmentPickerTileMetrics.cornerRadius, style: .continuous)
          .fill(.quaternary.opacity(0.8))
      )
      .contentShape(.rect(cornerRadius: AttachmentPickerTileMetrics.cornerRadius))
    }
    .buttonStyle(.plain)
  }
}

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
      ZStack(alignment: .bottomTrailing) {
        AttachmentPickerAssetThumbnail(
          localIdentifier: item.localIdentifier,
          mediaType: item.mediaType
        )
        .frame(
          width: AttachmentPickerTileMetrics.thumbnailWidth,
          height: AttachmentPickerTileMetrics.thumbnailHeight
        )
        .clipShape(.rect(cornerRadius: AttachmentPickerTileMetrics.cornerRadius))

        if item.mediaType == .video {
          Image(systemName: "video.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.55), in: Circle())
            .padding(8)
        }
      }
      .frame(
        width: AttachmentPickerTileMetrics.thumbnailWidth,
        height: AttachmentPickerTileMetrics.thumbnailHeight
      )
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
    .buttonStyle(.plain)
    .accessibilityLabel(item.mediaType == .video ? "Recent video" : "Recent photo")
    .accessibilityHint(isSelected ? "Double tap to deselect." : "Double tap to select.")
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
    .frame(width: 22, height: 22)
  }
}

private struct AttachmentPickerAssetThumbnail: View {
  let localIdentifier: String
  let mediaType: AttachmentPickerModel.RecentMediaType

  @State private var image: UIImage?
  @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: AttachmentPickerTileMetrics.cornerRadius, style: .continuous)
        .fill(.quaternary.opacity(0.6))

      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: mediaType == .video ? "video" : "photo")
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .clipped()
    .task(id: localIdentifier) {
      loadThumbnail()
    }
    .onDisappear {
      cancelThumbnailRequest()
    }
  }

  private func loadThumbnail() {
    cancelThumbnailRequest()

    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = assets.firstObject else {
      image = nil
      return
    }

    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true

    let size = CGSize(
      width: AttachmentPickerTileMetrics.thumbnailWidth * UIScreen.main.scale,
      height: AttachmentPickerTileMetrics.thumbnailHeight * UIScreen.main.scale
    )

    requestID = PHImageManager.default().requestImage(
      for: asset,
      targetSize: size,
      contentMode: .aspectFill,
      options: options
    ) { image, _ in
      self.image = image
    }
  }

  private func cancelThumbnailRequest() {
    guard requestID != PHInvalidImageRequestID else { return }
    PHImageManager.default().cancelImageRequest(requestID)
    requestID = PHInvalidImageRequestID
  }
}

extension View {
  @ViewBuilder
  func attachmentPickerSurface(cornerRadius: CGFloat, interactive: Bool) -> some View {
    if #available(iOS 26.0, *) {
      glassEffect(
        interactive ? .regular.interactive() : .regular,
        in: .rect(cornerRadius: cornerRadius)
      )
    } else {
      background(
        .thinMaterial,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
    }
  }
}
#endif
