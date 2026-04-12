#if os(iOS)
import Photos
import SwiftUI
import UIKit

private enum AttachmentPickerThumbnailManager {
  static let shared = PHCachingImageManager()
}

struct AttachmentPickerAssetThumbnail: View {
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
    image = nil

    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = assets.firstObject else {
      image = nil
      return
    }

    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.isSynchronous = false

    requestID = AttachmentPickerThumbnailManager.shared.requestImage(
      for: asset,
      targetSize: AttachmentPickerTileMetrics.thumbnailPixelSize,
      contentMode: .aspectFill,
      options: options
    ) { image, _ in
      self.image = image
    }
  }

  private func cancelThumbnailRequest() {
    guard requestID != PHInvalidImageRequestID else { return }
    AttachmentPickerThumbnailManager.shared.cancelImageRequest(requestID)
    requestID = PHInvalidImageRequestID
  }
}
#endif
