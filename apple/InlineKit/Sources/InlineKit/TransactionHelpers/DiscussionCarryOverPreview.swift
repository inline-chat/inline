import Foundation
import InlineProtocol

public extension FullMessage {
  /// Freeze visible content from the authorized wire projection. The warm
  /// database can preserve removed legacy media/cards, so it supplies sender
  /// decoration only and cannot certify this reviewed snapshot.
  func reviewedCarryOverSnapshot(from source: InlineProtocol.Message) -> FullMessage {
    var full = self
    let globalId = message.globalId
    full.message = Message(from: source)
    if case .nudge? = source.media.media {
      full.message.text = [source.hasMessage ? source.message : "", "👋 Nudge"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    full.message.globalId = globalId
    full.file = nil
    full.repliedToMessage = nil
    full.photoInfo = source.media.photo.hasPhoto ? Self.carryPhoto(source.media.photo.photo) : nil
    full.videoInfo = source.media.video.hasVideo ? VideoInfo(
      video: Video.from(proto: source.media.video.video, localPhotoId: nil),
      photoInfo: source.media.video.video.hasPhoto ? Self.carryPhoto(source.media.video.video.photo) : nil
    ) : nil
    full.documentInfo = source.media.document.hasDocument ? DocumentInfo(
      document: Document.from(proto: source.media.document.document),
      photoInfo: source.media.document.document.hasPhoto ? Self.carryPhoto(source.media.document.document.photo) : nil
    ) : nil
    full.attachments = source.attachments.attachments.compactMap { item in
      var attachment = Attachment(messageId: globalId, externalTaskId: nil, urlPreviewId: nil, attachmentId: item.id)
      attachment.id = item.id
      switch item.attachment {
      case let .externalTask(task)?:
        return FullAttachment(attachment: attachment, externalTask: ExternalTask(from: task))
      case let .urlPreview(preview)?:
        let photo: InlineProtocol.Photo? = preview.hasPhoto ? preview.photo : {
          switch preview.media.media {
          case let .photo(photo)?: photo
          case let .video(video)?: video.hasPhoto ? video.photo : nil
          case let .document(document)?: document.hasPhoto ? document.photo : nil
          default: nil
          }
        }()
        return FullAttachment(attachment: attachment,
          urlPreview: UrlPreview(id: preview.id, url: preview.url,
            siteName: preview.hasSiteName ? preview.siteName : nil,
            title: preview.hasTitle ? preview.title : nil,
            description: preview.hasDescription_p ? preview.description_p : nil,
            photoId: photo?.id, duration: preview.hasDuration ? preview.duration : nil,
            author: preview.hasAuthor ? preview.author : nil),
          photoInfo: photo.map(Self.carryPhoto))
      case nil: return nil
      }
    }
    return full
  }

  private static func carryPhoto(_ photo: InlineProtocol.Photo) -> PhotoInfo {
    PhotoInfo(photo: Photo.from(proto: photo), sizes: photo.sizes.map { PhotoSize.from(proto: $0, photoId: photo.id) })
  }

  /// Mirrors the server's historical text projection. Actions become labels;
  /// source links do not confer access or carry reply/child relationships.
  var discussionCarryOverText: String {
    var paragraphs = [message.text ?? ""]
    for attachment in attachments {
      guard let task = attachment.externalTask else { continue }
      let title = task.title.flatMap { $0.isEmpty ? nil : $0 } ?? task.taskId ?? ""
      paragraphs.append([task.application, task.number ?? "", title]
        .filter { !$0.isEmpty }.joined(separator: " · "))
      let status: String = switch task.status {
      case .unspecified: ""
      case .backlog: "Backlog"
      case .todo: "To do"
      case .inProgress: "In progress"
      case .done: "Done"
      case .cancelled: "Cancelled"
      }
      if !status.isEmpty { paragraphs.append("Status: \(status)") }
      if let assignee = task.assignedUserId, assignee > 0 { paragraphs.append("Assignee: inline://user/\(assignee)") }
      if let url = task.url { paragraphs.append(url) }
    }
    for row in message.actions?.rows ?? [] {
      paragraphs.append(row.actions.map(\.text).filter { !$0.isEmpty }.joined(separator: " · "))
    }
    if let replyId = message.repliedToMessageId { paragraphs.append("Reply: inline://chat/\(chatId)?message_id=\(replyId)") }
    if let child = message.threadCard {
      if let title = child.title { paragraphs.append(title) }
      paragraphs.append("inline://chat/\(child.chatId)")
    }
    paragraphs.append("Source: inline://chat/\(chatId)?message_id=\(message.messageId)")
    return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// Value-only media projection for the review sheet. Pending source images
  /// become unavailable history on the server, rather than future mutations.
  var discussionCarryOverBlockImages: [PhotoInfo?] {
    var images: [PhotoInfo?] = []
    func append(_ image: InlineProtocol.BlockImage) {
      if case let .ready(photo)? = image.state {
        let stored = Photo.from(proto: photo)
        images.append(PhotoInfo(photo: stored, sizes: photo.sizes.map { PhotoSize.from(proto: $0, photoId: stored.photoId) }))
      } else { images.append(nil) }
    }
    func visit(_ blocks: [InlineProtocol.Block]) {
      for block in blocks {
        switch block.kind {
        case let .image(image)?: append(image)
        case let .album(album)?: album.images.forEach(append)
        case let .quote(quote)?: visit(quote.children)
        case let .disclosure(disclosure)?: visit(disclosure.children)
        case let .list(list)?: list.items.forEach { visit($0.children) }
        default: break
        }
      }
    }
    if let payload = message.blockContentPayload { visit(payload.content.blocks) }
    return images
  }
}
