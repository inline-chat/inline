import GRDB
import InlineProtocol

/// Fixed tag spaces share canonical messages, but never share incomplete coverage.
public enum MessageHistoryScope: Int, Codable, CaseIterable, Sendable {
  case timeline = 0, photos, videos, media, files, voice, links

  public var filter: InlineProtocol.SearchMessagesFilter? {
    switch self {
      case .timeline: nil
      case .photos: .filterPhotos
      case .videos: .filterVideos
      case .media: .filterPhotoVideo
      case .files: .filterDocuments
      case .voice: .filterVoiceMemos
      case .links: .filterLinks
    }
  }

  public init?(filter: InlineProtocol.SearchMessagesFilter?) {
    switch filter {
      case nil, .filterUnspecified: self = .timeline
      case .filterPhotos: self = .photos
      case .filterVideos: self = .videos
      case .filterPhotoVideo: self = .media
      case .filterDocuments: self = .files
      case .filterVoiceMemos: self = .voice
      case .filterLinks: self = .links
      case .UNRECOGNIZED: return nil
    }
  }

  public var resourceMask: MessageResourceFlags {
    switch self {
      case .timeline: .all
      case .photos: .photo
      case .videos: .video
      case .media: [.photo, .video]
      case .files: .file
      case .voice: .voice
      case .links: .link
    }
  }

  public func matches(_ message: Message) -> Bool {
    self == .timeline || !MessageResourceFlags(rawValue: message.resourceFlags).intersection(resourceMask).isEmpty
  }
}

public struct MessageResourceFlags: OptionSet, Sendable {
  public let rawValue: Int64
  public init(rawValue: Int64) {
    self.rawValue = rawValue
  }

  public static let photo = Self(rawValue: 1 << 0)
  public static let video = Self(rawValue: 1 << 1)
  public static let file = Self(rawValue: 1 << 2)
  public static let voice = Self(rawValue: 1 << 3)
  public static let link = Self(rawValue: 1 << 4)
  public static let all: Self = [.photo, .video, .file, .voice, .link]

  public static func classify(_ message: Message) -> Self {
    var flags: Self = []
    // Match the protocol's media union, including legacy rows that still hold
    // an old file pointer alongside their modern attachment association.
    if message.photoId != nil {
      if message.isSticker != true {
        flags.insert(.photo)
      }
    } else if message.videoId != nil {
      if message.isSticker != true {
        flags.insert(.video)
      }
    } else if message.documentId != nil {
      if message.isSticker != true {
        flags.insert(.file)
      }
    } else if message.hasVoice {
      flags.insert(.voice)
    }
    if message.hasLink == true {
      flags.insert(.link)
    }
    return flags
  }

  public static func classify(_ message: InlineProtocol.Message) -> Self {
    var flags = classify(Message(from: message))
    if message.attachments.attachments.contains(where: {
      if case .urlPreview = $0.attachment {
        return true
      }
      return false
    }) {
      flags.insert(.link)
    }
    return flags
  }
}
