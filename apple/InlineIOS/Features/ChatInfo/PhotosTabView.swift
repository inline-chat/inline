import InlineKit
import Nuke
import NukeUI
import SwiftUI
import UIKit

struct PhotosTabView: View {
  @ObservedObject var photosViewModel: ChatPhotosViewModel
  let onShowInChat: (Message) -> Void

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
  @State private var prefetchTask: Task<Void, Never>?

  var body: some View {
    Group {
      if photosViewModel.photoMessages.isEmpty {
        VStack(spacing: 8) {
          Text("No photos found in this chat.")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
            ForEach(photosViewModel.groupedPhotoMessages, id: \.date) { group in
              Section {
                LazyVGrid(columns: columns, spacing: 2) {
                  ForEach(group.messages) { photoMessage in
                    PhotoGridThumbnailView(
                      url: photoURL(for: photoMessage.photo),
                      cornerRadius: 8
                    ) { imageView in
                      presentPhoto(photoMessage, from: imageView)
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                    .contextMenu {
                      Button {
                        onShowInChat(photoMessage.message)
                      } label: {
                        Label("Show in Chat", systemImage: "text.bubble")
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
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear(perform: prefetchVisible)
    .onChange(of: photosViewModel.photoMessages.count) { _ in
      prefetchVisible()
    }
    .onDisappear {
      prefetchTask?.cancel()
      prefetchTask = nil
    }
  }

  private func presentPhoto(_ photoMessage: PhotoMessage, from sourceView: UIView) {
    guard let url = photoURL(for: photoMessage.photo) else { return }

    let imageViewer = ImageViewerController(
      imageURL: url,
      sourceView: sourceView,
      sourceImage: (sourceView as? LazyImageView)?.imageView.image,
      showInChatAction: { onShowInChat(photoMessage.message) }
    )

    topViewController()?.present(imageViewer, animated: false)
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
    let urls = photosViewModel.photoMessages.prefix(60).compactMap { photoURL(for: $0.photo) }
    guard !urls.isEmpty else { return }

    prefetchTask = Task.detached(priority: .utility) {
      for url in urls {
        guard !Task.isCancelled else { return }
        _ = try? await ImagePipeline.shared.image(for: url)
      }
    }
  }
}

private struct PhotoGridThumbnailView: UIViewRepresentable {
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
