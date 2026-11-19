import Foundation
import InlineKit
import Logger
import Nuke
import SwiftUI
import UIKit

/// The Media tab: an edge-to-edge grid of square thumbnails under month titles, newest
/// first, like Photos and Telegram's shared media.
///
/// It is the content of a section in the chat info page's scroll view and owns no scroll
/// view of its own. Scrolling stays light because:
/// - one `LazyVGrid` holds every month, so cells are realized only near the viewport;
/// - each cell is one UIKit view whose image is decoded at its pixel size, shown from
///   the memory cache in the first frame when it's there, and never animates a spinner;
/// - cells are `Equatable` over their display data, so model updates skip unchanged cells;
/// - an appearing cell does an index compare for pagination and prefetching, not a task.
struct MediaTabView: View {
  @ObservedObject var mediaViewModel: ChatMediaViewModel
  let onShowInChat: (Message) -> Void

  @State private var model = ChatInfoResourceMediaModel()

  private static let spacing: CGFloat = 1
  /// Three columns on every iPhone in portrait, more on wider layouts.
  private static let columns = [GridItem(.adaptive(minimum: 110), spacing: spacing)]

  var body: some View {
    let sections = model.sections(for: mediaViewModel.mediaMessages)
    VStack(spacing: 0) {
      if !sections.isEmpty {
        LazyVGrid(columns: Self.columns, spacing: Self.spacing) {
          ForEach(sections) { section in
            Section {
              ForEach(section.items) { item in
                ChatInfoResourceMediaCell(
                  item: item,
                  model: model,
                  onOpen: openGallery,
                  onShowInChat: onShowInChat
                )
                .equatable()
                .onAppear { model.itemAppeared(item.index, window: mediaViewModel) }
              }
            } header: {
              ChatInfoResourceSectionHeader(title: section.title, inset: 16)
            }
          }
        }
      }

      ChatInfoResourceFooter(
        state: mediaViewModel.loadState,
        rowCount: mediaViewModel.mediaMessages.count,
        empty: .init(systemImage: "photo.on.rectangle", message: "No media yet"),
        onReachEnd: { model.pager.requestMore(mediaViewModel) },
        retry: { model.pager.retry(mediaViewModel) }
      )
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .task {
      #if DEBUG
      await ChatInfoResourceHarness.seedIfRequested()
      #endif
      await mediaViewModel.loadInitial()
    }
    .onDisappear {
      mediaViewModel.deactivate()
      model.prefetcher.stop()
    }
  }

  /// Opens the chat's media gallery at this item, paging through all of the chat's media.
  private func openGallery(_ item: ChatInfoResourceMediaItem, from sourceView: ChatInfoResourceThumbnailView) {
    let media = item.media
    guard let anchor = MediaGalleryItem(message: media.message, photo: media.photo, video: media.video) else { return }

    var actions = MediaGalleryViewController.Actions()
    actions.showInChat = { galleryItem in
      if let message = galleryItem.message { onShowInChat(message) }
    }
    let canDeleteMessage = MessageDeletePolicy.checker(peer: media.message.peerId)
    actions.canDelete = { galleryItem in galleryItem.message.map(canDeleteMessage) ?? false }
    actions.delete = { galleryItem in
      guard let message = galleryItem.message else { return }
      MessageViewActions.sendDeleteMessage(messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
    }
    let registry = model.registry
    let viewer = MediaGalleryViewController(
      source: ChatMediaGallerySource(chatId: media.message.chatId, peer: media.message.peerId, anchor: anchor),
      initialItemID: anchor.id,
      sourceImage: sourceView.imageView.image,
      sourceCornerRadius: 0,
      actions: actions,
      // Gallery items use message ids, so it can close into any thumbnail still on screen.
      sourceViewProvider: { [weak registry] galleryItem in registry?.view(for: galleryItem.id) }
    )
    activeTopViewController()?.present(viewer, animated: false)
  }
}

/// A media message prepared for display once per page, not per cell render.
struct ChatInfoResourceMediaItem: Identifiable, Equatable {
  let id: Int64
  /// Position in the whole grid, for pagination and prefetching.
  let index: Int
  let media: MediaMessage
  let thumbnail: ChatInfoResourceThumbnailContent

  @MainActor
  init(media: MediaMessage, index: Int) {
    id = media.id
    self.index = index
    self.media = media
    let date = ChatInfoResourceFormat.rowDate(media.message.date)
    if let video = media.video {
      let duration = video.video.duration.flatMap { $0 > 0 ? ChatInfoResourceFormat.duration($0) : nil }
      thumbnail = ChatInfoResourceThumbnailContent(
        photo: video.thumbnail,
        badgeText: duration,
        accessibilityLabel: [String(localized: "Video"), duration, date].compactMap(\.self).joined(separator: ", ")
      )
    } else {
      thumbnail = ChatInfoResourceThumbnailContent(
        photo: media.photo,
        accessibilityLabel: [String(localized: "Photo"), date].joined(separator: ", ")
      )
    }
  }
}

/// State the media tab keeps across renders: sections, pagination, prefetching and
/// the thumbnails on screen. Plain reference state; none of it drives rendering.
@MainActor
final class ChatInfoResourceMediaModel {
  let pager = ChatInfoResourcePager()
  let registry = ChatInfoResourceViewRegistry()
  /// About four rows ahead on a phone.
  let prefetcher = ChatInfoResourceThumbnailPrefetcher(lookahead: 18)
  private let cache = ChatInfoResourceSectionCache<MediaMessage, ChatInfoResourceMediaItem>()

  func sections(for rows: [MediaMessage]) -> [ChatInfoResourceSection<ChatInfoResourceMediaItem>] {
    cache.sections(for: rows, date: \.message.date, id: \.message.messageId) { media, placement in
      ChatInfoResourceMediaItem(media: media, index: placement.index)
    }
  }

  func itemAppeared(_ index: Int, window: ChatMediaViewModel) {
    let items = cache.items
    // Start the next page about two screens before the end.
    pager.itemAppeared(at: index, count: items.count, lookahead: 36, in: window)
    prefetcher.itemAppeared(at: index) { range in
      items[range.clamped(to: items.indices)].compactMap(\.thumbnail.url)
    }
  }
}

private struct ChatInfoResourceMediaCell: View, Equatable {
  let item: ChatInfoResourceMediaItem
  let model: ChatInfoResourceMediaModel
  let onOpen: (ChatInfoResourceMediaItem, ChatInfoResourceThumbnailView) -> Void
  let onShowInChat: (Message) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.model === rhs.model
  }

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        ChatInfoResourceThumbnail(
          id: item.id,
          content: item.thumbnail,
          registry: model.registry,
          onPixelSize: { [prefetcher = model.prefetcher] in prefetcher.update(pixelSize: $0) },
          onTap: { [item, onOpen] view in onOpen(item, view) }
        )
      }
      .contentShape(.contextMenuPreview, Rectangle())
      .contextMenu {
        ChatInfoResourceMediaMenu(media: item.media, onShowInChat: onShowInChat)
      }
  }
}

/// Show in Chat, Save and Share. URLs resolve when an action runs, never while the
/// menu is built, since a video's local file has to be checked on disk.
private struct ChatInfoResourceMediaMenu: View {
  let media: MediaMessage
  let onShowInChat: (Message) -> Void

  var body: some View {
    Button {
      onShowInChat(media.message)
    } label: {
      Label("Show in Chat", systemImage: "text.bubble")
    }
    if let photo = media.photo {
      Button {
        Self.savePhoto(photo)
      } label: {
        Label("Save Photo", systemImage: "square.and.arrow.down")
      }
      if Self.photoURL(for: photo) != nil {
        Button {
          if let url = Self.photoURL(for: photo) { Self.share(url) }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      }
    } else if let video = media.video {
      Button {
        Self.saveVideo(video)
      } label: {
        Label("Save Video", systemImage: "square.and.arrow.down")
      }
      if video.video.localPath != nil || video.video.cdnUrl != nil {
        Button {
          if let url = Self.videoURL(for: video) { Self.share(url) }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      }
    }
  }

  private static func photoURL(for photo: PhotoInfo) -> URL? {
    ChatInfoResourceThumbnailContent(photo: photo).url
  }

  private static func videoURL(for video: VideoInfo) -> URL? {
    if let localPath = video.video.localPath {
      let localURL = FileCache.getUrl(for: .videos, localPath: localPath)
      if FileManager.default.fileExists(atPath: localURL.path) {
        return localURL
      }
    }
    return video.video.cdnUrl.flatMap(URL.init(string:))
  }

  private static func savePhoto(_ photo: PhotoInfo) {
    guard let url = photoURL(for: photo) else {
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

  private static func saveVideo(_ video: VideoInfo) {
    guard let url = videoURL(for: video) else {
      Log.shared.error("MediaTabView: no video URL available for saving")
      return
    }
    if url.isFileURL {
      UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
      return
    }
    Task {
      do {
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        UISaveVideoAtPathToSavedPhotosAlbum(tempURL.path, nil, nil, nil)
      } catch {
        Log.shared.error("MediaTabView: failed to download video for saving", error: error)
      }
    }
  }

  private static func share(_ url: URL) {
    guard let presenter = activeTopViewController() else {
      Log.shared.error("MediaTabView: unable to find presenter for share sheet")
      return
    }
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
    }
    presenter.present(controller, animated: true)
  }
}
