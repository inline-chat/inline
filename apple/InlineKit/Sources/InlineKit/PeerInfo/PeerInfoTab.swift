import Foundation

/// A collection under the chat info header.
public enum PeerInfoTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  /// People and groups with access to a thread.
  case members
  /// Subthreads of a thread, or threads shared with a person or bot.
  case threads
  case media
  case files
  case voice
  case links

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .members: String(localized: "Members")
    case .threads: String(localized: "Threads")
    case .media: String(localized: "Media")
    case .files: String(localized: "Files")
    case .voice: String(localized: "Voice")
    case .links: String(localized: "Links")
    }
  }

  public var systemImage: String {
    switch self {
    case .members: "person.2"
    case .threads: "bubble.left.and.bubble.right"
    case .media: "photo.on.rectangle"
    case .files: "doc"
    case .voice: "waveform"
    case .links: "link"
    }
  }

  /// Message-backed collections, loaded through chat history resources.
  public var isResource: Bool {
    switch self {
    case .media, .files, .voice, .links: true
    case .members, .threads: false
    }
  }

  /// The tabs for a subject, in display order. The first one opens by default.
  ///
  /// Every subject keeps all four resource tabs so the bar never changes shape
  /// while history loads.
  public static func tabs(for subject: PeerInfoSubject) -> [PeerInfoTab] {
    let resources: [PeerInfoTab] = [.media, .files, .voice, .links]
    switch subject.kind {
    case .selfChat:
      return resources
    case .person, .bot:
      return [.threads] + resources
    case .thread:
      return [.members, .threads] + resources
    case .subthread:
      return [.members] + resources
    }
  }
}
