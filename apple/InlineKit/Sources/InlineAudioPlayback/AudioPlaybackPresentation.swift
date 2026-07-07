import Foundation

/// Platform-neutral chat peer identity used only for navigation metadata.
public enum AudioPlaybackPeer: Codable, Equatable, Hashable, Sendable {
  case user(id: Int64)
  case thread(id: Int64)
}

/// Metadata a platform UI can use to open the source message for the active item.
public struct AudioPlaybackOpenTarget: Codable, Equatable, Hashable, Sendable {
  public var peer: AudioPlaybackPeer
  public var chatId: Int64
  public var messageId: Int64

  public init(peer: AudioPlaybackPeer, chatId: Int64, messageId: Int64) {
    self.peer = peer
    self.chatId = chatId
    self.messageId = messageId
  }
}

/// Human-readable now-playing labels supplied by app-specific adapters.
public struct AudioPlaybackDisplay: Codable, Equatable, Hashable, Sendable {
  public var title: String
  public var parentTitle: String?
  public var subtitle: String?

  public init(title: String, parentTitle: String? = nil, subtitle: String? = nil) {
    self.title = title
    self.parentTitle = parentTitle
    self.subtitle = subtitle
  }
}

/// Full UI presentation payload for one playback request.
public struct AudioPlaybackPresentation: Codable, Equatable, Hashable, Sendable {
  public var display: AudioPlaybackDisplay
  public var openTarget: AudioPlaybackOpenTarget?

  public init(display: AudioPlaybackDisplay, openTarget: AudioPlaybackOpenTarget? = nil) {
    self.display = display
    self.openTarget = openTarget
  }
}
