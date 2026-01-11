import Foundation
import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI
import UIKit

struct MediaTabView: View {
  @ObservedObject var mediaViewModel: ChatMediaViewModel
  let onShowInChat: (Message) -> Void

  private let gridSpacing: CGFloat = 2
  private let minItemSize: CGFloat = 100
  @State private var prefetchTask: Task<Void, Never>?

  private var columns: [GridItem] {
    [GridItem(.adaptive(minimum: minItemSize), spacing: gridSpacing)]
  }

  var body: some View {
    Group {
      if mediaViewModel.mediaMessages.isEmpty {
        VStack(spacing: 8) {
          Text("No media found in this chat.")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
          ForEach(mediaViewModel.groupedMediaMessages, id: \.date) { group in
            Section {
              LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(group.messages) { mediaMessage in
                  mediaCell(for: mediaMessage)
                    .onAppear {
                      Task {
                        await mediaViewModel.loadMoreIfNeeded(currentMessageId: mediaMessage.message.id)
                      }
                    }
                }
              }
            } header: {
              DateBadge(dateText: formatDate(group.date))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .background(.thinMaterial)
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .task {
      await mediaViewModel.loadInitial()
    }
    .onAppear(perform: prefetchVisible)
    .onChange(of: mediaViewModel.mediaMessages.count) { _ in
      prefetchVisible()
    }
    .onDisappear {
      prefetchTask?.cancel()
      prefetchTask = nil
    }
  }

  @ViewBuilder
  private func mediaCell(for mediaMessage: MediaMessage) -> some View {
    ZStack {
      Rectangle()
        .fill(Color(.systemGray5))

      MediaGridThumbnailView(
        url: thumbnailURL(for: mediaMessage),
        cornerRadius: 8
      ) { imageView in
        presentMedia(mediaMessage, from: imageView)
      }

      if let videoInfo = mediaMessage.video {
        MediaVideoOverlay(duration: videoInfo.video.duration)
          .allowsHitTesting(false)
      }
    }
    .aspectRatio(1, contentMode: .fill)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contextMenu {
      // we don't support navigating to arbitary places i nchat yet
//      Button {
//        onShowInChat(mediaMessage.message)
//      } label: {
//        Label("Show in Chat", systemImage: "text.bubble")
//      }
      switch mediaMessage.kind {
        case let .photo(photoInfo):
          Button {
            savePhoto(photoInfo)
          } label: {
            Label("Save Photo", systemImage: "square.and.arrow.down")
          }
          if let url = photoURL(for: photoInfo) {
            Button {
              shareMedia(url: url)
            } label: {
              Label("Share", systemImage: "square.and.arrow.up")
            }
          }
        case let .video(videoInfo):
          Button {
            saveVideo(videoInfo)
          } label: {
            Label("Save Video", systemImage: "square.and.arrow.down")
          }
          if let url = videoURL(for: videoInfo) {
            Button {
              shareMedia(url: url)
            } label: {
              Label("Share", systemImage: "square.and.arrow.up")
            }
          }
        case .none:
          EmptyView()
      }
    }
  }

  private func presentMedia(_ mediaMessage: MediaMessage, from sourceView: UIView) {
    switch mediaMessage.kind {
      case let .photo(photoInfo):
        guard let url = photoURL(for: photoInfo) else { return }
        let imageViewer = ImageViewerController(
          imageURL: url,
          sourceView: sourceView,
          sourceImage: (sourceView as? LazyImageView)?.imageView.image
//          showInChatAction: { onShowInChat(mediaMessage.message) }
        )
        topViewController()?.present(imageViewer, animated: false)
      case let .video(videoInfo):
        guard let url = videoURL(for: videoInfo) else { return }
        let imageViewer = ImageViewerController(
          videoURL: url,
          sourceView: sourceView,
          sourceImage: (sourceView as? LazyImageView)?.imageView.image
//          showInChatAction: { onShowInChat(mediaMessage.message) }
        )
        topViewController()?.present(imageViewer, animated: false)
      case .none:
        return
    }
  }

  private func thumbnailURL(for mediaMessage: MediaMessage) -> URL? {
    if let photo = mediaMessage.photo {
      return photoURL(for: photo)
    }
    if let thumbnail = mediaMessage.video?.thumbnail {
      return photoURL(for: thumbnail)
    }
    return nil
  }

  private func photoURL(for photoInfo: PhotoInfo) -> URL? {
    guard let photoSize = photoInfo.bestPhotoSize() else { return nil }

    if let localPath = photoSize.localPath {
      return FileCache.getUrl(for: .photos, localPath: localPath)
    }

    if let cdnUrl = photoSize.cdnUrl {
      return URL(string: cdnUrl)
    }

    return nil
  }

  private func videoURL(for videoInfo: VideoInfo) -> URL? {
    if let localPath = videoInfo.video.localPath {
      let localUrl = FileCache.getUrl(for: .videos, localPath: localPath)
      if FileManager.default.fileExists(atPath: localUrl.path) {
        return localUrl
      }
    }

    if let cdnUrl = videoInfo.video.cdnUrl {
      return URL(string: cdnUrl)
    }

    return nil
  }

  private func savePhoto(_ photoInfo: PhotoInfo) {
    guard let url = photoURL(for: photoInfo) else {
      Log.shared.error("MediaTabView: no photo URL available for saving")
      return
    }

    Task {
      do {
        let image = try await ImagePipeline.shared.image(for: url)
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
      } catch {
        Log.shared.error("MediaTabView: failed to load photo for saving", error: error)
      }
    }
  }

  private func saveVideo(_ videoInfo: VideoInfo) {
    if let localUrl = videoURL(for: videoInfo), localUrl.isFileURL {
      UISaveVideoAtPathToSavedPhotosAlbum(localUrl.path, nil, nil, nil)
      return
    }

    guard let remoteUrl = videoURL(for: videoInfo) else {
      Log.shared.error("MediaTabView: no video URL available for saving")
      return
    }

    Task {
      do {
        let (tempUrl, _) = try await URLSession.shared.download(from: remoteUrl)
        UISaveVideoAtPathToSavedPhotosAlbum(tempUrl.path, nil, nil, nil)
      } catch {
        Log.shared.error("MediaTabView: failed to download video for saving", error: error)
      }
    }
  }

  private func shareMedia(url: URL) {
    guard let presenter = topViewController() else {
      Log.shared.error("MediaTabView: unable to find presenter for share sheet")
      return
    }

    let activityViewController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popoverController = activityViewController.popoverPresentationController {
      popoverController.sourceView = presenter.view
      popoverController.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 1,
        height: 1
      )
    }
    presenter.present(activityViewController, animated: true)
  }

  private func formatDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMMM d, yyyy"
      return formatter.string(from: date)
    }
  }

  private func topViewController(from controller: UIViewController? = nil) -> UIViewController? {
    let baseController: UIViewController?
    if let controller {
      baseController = controller
    } else {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }

      baseController = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ??
        UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }

    guard let baseController else { return nil }

    if let navigationController = baseController as? UINavigationController {
      return topViewController(from: navigationController.visibleViewController)
    } else if let tabController = baseController as? UITabBarController {
      return topViewController(from: tabController.selectedViewController)
    } else if let presented = baseController.presentedViewController {
      return topViewController(from: presented)
    }

    return baseController
  }

  private func prefetchVisible() {
    prefetchTask?.cancel()
    let urls = mediaViewModel.mediaMessages.prefix(60).compactMap { thumbnailURL(for: $0) }
    guard !urls.isEmpty else { return }

    prefetchTask = Task.detached(priority: .utility) {
      for url in urls {
        guard !Task.isCancelled else { return }
        _ = try? await ImagePipeline.shared.image(for: url)
      }
    }
  }
}

private struct MediaGridThumbnailView: UIViewRepresentable {
  let url: URL?
  let cornerRadius: CGFloat
  let onTap: (LazyImageView) -> Void

  func makeUIView(context: Context) -> LazyImageView {
    let imageView = LazyImageView()
    imageView.contentMode = .scaleAspectFill
    imageView.imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = cornerRadius
    imageView.priority = .high

    let indicator = UIActivityIndicatorView(style: .medium)
    indicator.color = .secondaryLabel
    indicator.startAnimating()
    imageView.placeholderView = indicator

    let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
    imageView.addGestureRecognizer(tapGesture)
    imageView.isUserInteractionEnabled = true

    return imageView
  }

  func updateUIView(_ uiView: LazyImageView, context: Context) {
    context.coordinator.onTap = { [weak uiView] in
      guard let uiView else { return }
      onTap(uiView)
    }

    let currentUrl = uiView.request?.url ?? uiView.url
    guard currentUrl != url else { return }

    uiView.imageView.image = nil
    if let indicator = uiView.placeholderView as? UIActivityIndicatorView {
      url == nil ? indicator.stopAnimating() : indicator.startAnimating()
    }

    if let url {
      uiView.request = ImageRequest(url: url)
    } else {
      uiView.url = nil
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  class Coordinator {
    var onTap: (() -> Void)?

    @objc func handleTap() {
      onTap?()
    }
  }
}

private struct MediaVideoOverlay: View {
  let duration: Int?

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [.clear, .black.opacity(0.35)],
        startPoint: .center,
        endPoint: .bottom
      )

      VStack {
        Spacer()
        HStack {
          Image(systemName: "play.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)

          Spacer()

          if let durationText = formatDuration(duration) {
            Text(durationText)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.black.opacity(0.5), in: Capsule())
          }
        }
        .padding(8)
      }
    }
  }

  private func formatDuration(_ duration: Int?) -> String? {
    guard let duration, duration > 0 else { return nil }
    let mins = duration / 60
    let secs = duration % 60
    if mins >= 60 {
      let hours = mins / 60
      let remMins = mins % 60
      return String(format: "%d:%02d:%02d", hours, remMins, secs)
    }
    return String(format: "%d:%02d", mins, secs)
  }
}

private struct DateBadge: View {
  let dateText: String

  var body: some View {
    Text(dateText)
      .font(.subheadline)
      .fontWeight(.medium)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(Color(.systemBackground).opacity(0.95))
      )
  }
}
