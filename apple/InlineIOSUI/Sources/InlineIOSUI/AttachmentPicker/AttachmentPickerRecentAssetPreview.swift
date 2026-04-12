#if os(iOS)
import AVKit
import Photos
import SwiftUI
import UIKit

struct AttachmentPickerRecentAssetPreview: View {
  let item: AttachmentPickerModel.RecentItem

  @State private var image: UIImage?
  @State private var player: AVPlayer?
  @State private var errorMessage: String?

  var body: some View {
    ZStack {
      Color.black

      if let player {
        AttachmentPickerPreviewVideoPlayer(player: player)
          .frame(width: 320, height: 320)
          .clipShape(.rect(cornerRadius: 20))
          .padding(12)
          .onAppear {
            player.play()
          }
      } else if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .padding(8)
      } else if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.9))
          .multilineTextAlignment(.center)
          .padding(16)
      } else {
        ProgressView()
          .tint(.white)
      }
    }
    .frame(width: 344, height: 344)
    .task(id: item.localIdentifier) {
      await loadPreview()
    }
    .onDisappear {
      player?.pause()
      player = nil
    }
  }

  @MainActor
  private func loadPreview() async {
    image = nil
    player?.pause()
    player = nil
    errorMessage = nil

    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil)
    guard let asset = assets.firstObject else {
      errorMessage = "Preview unavailable."
      return
    }

    switch item.mediaType {
    case .image:
      image = await loadImagePreview(for: asset)
      if image == nil {
        errorMessage = "Preview unavailable."
      }
    case .video:
      player = await loadVideoPreview(for: asset)
      if player == nil {
        errorMessage = "Preview unavailable."
      }
    }
  }

  private func loadImagePreview(for asset: PHAsset) async -> UIImage? {
    let scale = UIScreen.main.scale
    let targetSize = CGSize(
      width: UIScreen.main.bounds.width * scale,
      height: UIScreen.main.bounds.height * scale
    )

    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    options.version = .current

    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: targetSize,
        contentMode: .aspectFit,
        options: options
      ) { image, info in
        if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: image)
      }
    }
  }

  private func loadVideoPreview(for asset: PHAsset) async -> AVPlayer? {
    let options = PHVideoRequestOptions()
    options.deliveryMode = .automatic
    options.isNetworkAccessAllowed = true
    options.version = .current

    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
        if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
          continuation.resume(returning: nil)
          return
        }

        guard let item else {
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: AVPlayer(playerItem: item))
      }
    }
  }
}

private struct AttachmentPickerPreviewVideoPlayer: UIViewRepresentable {
  let player: AVPlayer

  func makeUIView(context: Context) -> AttachmentPickerPreviewVideoView {
    let view = AttachmentPickerPreviewVideoView()
    view.player = player
    return view
  }

  func updateUIView(_ uiView: AttachmentPickerPreviewVideoView, context: Context) {
    uiView.player = player
  }
}

private final class AttachmentPickerPreviewVideoView: UIView {
  override static var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  var player: AVPlayer? {
    get { playerLayer.player }
    set { playerLayer.player = newValue }
  }

  private var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    playerLayer.videoGravity = .resizeAspect
    backgroundColor = .black
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
#endif
