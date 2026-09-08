import Auth
import Foundation
import GRDB
import InlineProtocol

public enum ChatFileKind: String, CaseIterable, Sendable {
  case file, image, video
}

public enum ChatFileSort: String, Sendable {
  case name, kind, date, size
}

/// A sharing occurrence, held only by the browser. Never imported as timeline history.
public struct ChatFileEntry: Identifiable, Sendable {
  public struct ID: Hashable, Sendable {
    public let chatID: Int64
    public let messageID: Int64
    public let mediaID: Int64
    public let mediaType: String
  }

  public let id: ID
  public let message: InlineProtocol.Message
  public let name: String
  public let kind: ChatFileKind
  public let size: Int64
  public var date: Date {
    Date(timeIntervalSince1970: TimeInterval(message.date))
  }

  public var peer: Peer {
    message.peerID.toPeer()
  }

  public init?(_ message: InlineProtocol.Message) {
    guard message.id > 0, message.chatID > 0, !message.isSticker else { return nil }
    self.message = message
    let mediaID: Int64
    let mediaType: String
    switch message.media.media {
      case let .document(value):
        let document = value.document
        mediaID = document.id
        mediaType = "document"
        name = document.fileName.isEmpty ? "File \(message.id)" : document.fileName
        let mime = document.mimeType.lowercased()
        kind = mime.hasPrefix("image/") ? .image : mime.hasPrefix("video/") ? .video : .file
        size = Int64(max(0, document.size))
      case let .photo(value):
        mediaID = value.photo.id
        mediaType = "photo"
        name = "Image \(message.id)\(value.photo.format.toExtension())"
        kind = .image
        size = Int64(value.photo.sizes.filter { $0.type != "s" }.map(\.size).max() ?? 0)
      case let .video(value):
        mediaID = value.video.id
        mediaType = "video"
        name = "Video \(message.id).mp4"
        kind = .video
        size = Int64(max(0, value.video.size))
      default:
        return nil
    }
    guard mediaID > 0 else { return nil }
    id = ID(chatID: message.chatID, messageID: message.id, mediaID: mediaID, mediaType: mediaType)
  }

  public static func sorted(_ entries: [Self], by sort: ChatFileSort, ascending: Bool) -> [Self] {
    entries.sorted { lhs, rhs in
      let comparison: ComparisonResult = switch sort {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .kind: lhs.kind.rawValue.compare(rhs.kind.rawValue)
        case .date: lhs.date.compare(rhs.date)
        case .size:
          lhs.size == rhs.size ? .orderedSame : lhs.size < rhs.size ? .orderedAscending : .orderedDescending
      }
      if comparison == .orderedSame {
        if lhs.id.chatID != rhs.id.chatID { return lhs.id.chatID < rhs.id.chatID }
        return lhs.id.messageID > rhs.id.messageID
      }
      return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
  }
}

public enum ChatFileBrowserError: LocalizedError {
  case invalidPage, unavailable, downloadFailed

  public var errorDescription: String? {
    switch self {
      case .invalidPage: "Couldn’t load this file list. Try refreshing."
      case .unavailable: "This file is no longer available in the chat."
      case .downloadFailed: "Couldn’t download this file. Try again."
    }
  }
}

/// Independent cursors for the two existing filter-only queries. Cursor progress
/// follows raw server rows, including stickers excluded from presentation.
public struct ChatFileListing: Sendable {
  public static let pageSize: Int32 = 50
  public struct Cursor: Sendable {
    public var beforeID: Int64?
    public var isComplete = false
    public init() {}
  }

  public private(set) var entries: [ChatFileEntry] = []
  public private(set) var documents = Cursor()
  public private(set) var media = Cursor()
  public var isComplete: Bool {
    documents.isComplete && media.isComplete
  }

  public init() {}

  public func appending(
    documents documentPage: [InlineProtocol.Message]?,
    media mediaPage: [InlineProtocol.Message]?,
    chatID: Int64
  ) throws -> Self {
    var result = self
    var incoming: [ChatFileEntry] = []
    for (page, cursor, isDocument) in [(documentPage, documents, true), (mediaPage, media, false)] {
      guard let page else { continue }
      guard !cursor.isComplete, page.count <= Int(Self.pageSize) else { throw ChatFileBrowserError.invalidPage }
      var previous = cursor.beforeID ?? Int64.max
      for message in page {
        guard message.chatID == chatID, message.id > 0, message.id < previous else {
          throw ChatFileBrowserError.invalidPage
        }
        switch message.media.media {
          case .document where isDocument: break
          case .photo where !isDocument: break
          case .video where !isDocument: break
          default: throw ChatFileBrowserError.invalidPage
        }
        previous = message.id
        if let entry = ChatFileEntry(message) { incoming.append(entry) }
      }
      var next = cursor
      next.beforeID = page.last?.id ?? cursor.beforeID
      next.isComplete = page.count < Int(Self.pageSize)
      if isDocument { result.documents = next } else { result.media = next }
    }
    var ids = Set(result.entries.map(\.id))
    result.entries.append(contentsOf: incoming.filter { ids.insert($0.id).inserted })
    return result
  }
}

public enum ChatFileBrowser {
  public static func loadMore(peer: Peer, chatID: Int64, listing: ChatFileListing) async throws -> ChatFileListing {
    let auth = Auth.shared.handle
    let token = try auth.beginAccountMutation()
    func fetch(
      _ cursor: ChatFileListing.Cursor,
      filter: SearchMessagesFilter
    ) async throws -> [InlineProtocol.Message]? {
      guard !cursor.isComplete else { return nil }
      let response = try await Api.realtime.callRpcDirect(
        method: .searchMessages,
        input: .searchMessages(.with {
          $0.peerID = peer.toInputPeer()
          $0.filter = filter
          $0.limit = ChatFileListing.pageSize
          if let beforeID = cursor.beforeID { $0.offsetID = beforeID }
        }),
        timeout: .seconds(30), accountToken: token
      )
      try auth.validateAccountMutation(token)
      try Task.checkCancellation()
      guard case let .searchMessages(result)? = response else { throw ChatFileBrowserError.invalidPage }
      return result.messages
    }
    // Bounded reads, no query transaction reducer or Message.save side effects.
    let documents = try await fetch(listing.documents, filter: .filterDocuments)
    let media = try await fetch(listing.media, filter: .filterPhotoVideo)
    try auth.validateAccountMutation(token)
    return try listing.appending(documents: documents, media: media, chatID: chatID)
  }

  /// Reauthorize and refresh a selected occurrence before using the existing
  /// transfer/cache owners. Only media records are materialized in the database.
  @MainActor
  public static func localURL(for entry: ChatFileEntry, database: AppDatabase) async throws -> URL {
    let auth = Auth.shared.handle
    let token = try auth.beginAccountMutation()
    let response = try await Api.realtime.callRpcDirect(
      method: .getMessages,
      input: .getMessages(.with {
        $0.peerID = entry.peer.toInputPeer()
        $0.messageIds = [entry.id.messageID]
      }), timeout: .seconds(30), accountToken: token
    )
    try auth.validateAccountMutation(token)
    try Task.checkCancellation()
    guard case let .getMessages(result)? = response,
          let message = result.messages.first(where: { $0.chatID == entry.id.chatID && $0.id == entry.id.messageID }),
          ChatFileEntry(message)?.id == entry.id
    else { throw ChatFileBrowserError.unavailable }

    let item: FileMediaItem = try await database.dbWriter.write { db in
      try auth.validateAccountMutation(token)
      func photoInfo(_ proto: InlineProtocol.Photo) throws -> PhotoInfo {
        let photo = try Photo.updateFromProtocol(db, protoPhoto: proto)
        let sizes = try PhotoSize.filter(PhotoSize.Columns.photoId == photo.id).fetchAll(db)
        return PhotoInfo(photo: photo, sizes: sizes)
      }
      switch message.media.media {
        case let .document(value):
          let thumbnail = try value.document.hasPhoto ? photoInfo(value.document.photo) : nil
          let document = try Document.updateFromProtocol(
            db,
            protoDocument: value.document,
            thumbnailPhotoId: thumbnail?.id
          )
          return .document(DocumentInfo(document: document, photoInfo: thumbnail))
        case let .photo(value):
          return try .photo(photoInfo(value.photo))
        case let .video(value):
          let thumbnail = try value.video.hasPhoto ? photoInfo(value.video.photo) : nil
          let video = try Video.updateFromProtocol(db, protoVideo: value.video, thumbnailPhotoId: thumbnail?.id)
          return .video(VideoInfo(video: video, photoInfo: thumbnail))
        default: throw ChatFileBrowserError.unavailable
      }
    }
    try auth.validateAccountMutation(token)
    if let url = item.localFileURL(), FileManager.default.fileExists(atPath: url.path) { return url }
    let localMessage = Message(from: message)
    let url: URL
    switch item {
      case let .photo(photo):
        guard let downloaded = await FileCache.shared.downloadAndWait(photo: photo) else {
          throw ChatFileBrowserError.downloadFailed
        }
        url = downloaded
      case let .document(document):
        url = try await withCheckedThrowingContinuation { continuation in
          FileDownloader.shared.downloadDocument(document: document, for: localMessage) {
            continuation.resume(with: $0)
          }
        }
      case let .video(video):
        url = try await withCheckedThrowingContinuation { continuation in
          FileDownloader.shared.downloadVideo(video: video, for: localMessage) {
            continuation.resume(with: $0)
          }
        }
      case .voice: throw ChatFileBrowserError.unavailable
    }
    try auth.validateAccountMutation(token)
    try Task.checkCancellation()
    return url
  }
}
