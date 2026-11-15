import Combine
import Foundation
import InlineProtocol

/// A bot's guess at the current user's next message in a chat (Claude Code's
/// prompt suggestion, Codex's composer prediction), shown as the composer's
/// gray placeholder and inserted with Tab. Live only: kept in memory, never
/// stored, and dropped once a newer message arrives from anyone other than the
/// bot, or the user types, sends or dismisses it.
@MainActor
public final class ComposeSuggestions {
  public struct Suggestion: Equatable, Sendable {
    public let peer: Peer
    /// The bot that suggested it.
    public let botUserID: Int64
    public let text: String
    /// The message it follows; newer messages from others make it stale.
    public let afterMessageID: Int64?

    public init(peer: Peer, botUserID: Int64, text: String, afterMessageID: Int64?) {
      self.peer = peer
      self.botUserID = botUserID
      self.text = text
      self.afterMessageID = afterMessageID
    }
  }

  public static let shared = ComposeSuggestions()

  private var suggestions: [Peer: Suggestion] = [:]
  /// The newest message seen per chat and sender, for suggestions that arrive
  /// after the conversation moved on.
  private var newestMessage: [Peer: [Int64: Int64]] = [:]
  private let subject = PassthroughSubject<Peer, Never>()

  /// Peers whose suggestion changed.
  public var changes: AnyPublisher<Peer, Never> { subject.eraseToAnyPublisher() }

  public init() {}

  public func suggestion(for peer: Peer) -> Suggestion? {
    suggestions[peer]
  }

  /// Applies a server update: a new suggestion, or a clear when empty.
  public func apply(_ update: InlineProtocol.UpdateComposeSuggestion) {
    let peer = update.peerID.toPeer()
    let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      if suggestions[peer]?.botUserID == update.userID { remove(peer) }
      return
    }
    let afterMessageID = update.hasAfterMessageID ? update.afterMessageID : nil
    if let afterMessageID,
       newestMessage[peer, default: [:]].contains(where: { $0.key != update.userID && $0.value > afterMessageID })
    {
      return
    }
    let suggestion = Suggestion(peer: peer, botUserID: update.userID, text: text, afterMessageID: afterMessageID)
    guard suggestions[peer] != suggestion else { return }
    suggestions[peer] = suggestion
    subject.send(peer)
  }

  /// A message landed in `peer`: one from anyone but the suggesting bot ends
  /// the suggestion.
  public func noteMessage(peer: Peer, fromUserID: Int64, messageID: Int64) {
    newestMessage[peer, default: [:]][fromUserID] = max(messageID, newestMessage[peer]?[fromUserID] ?? 0)
    guard let suggestion = suggestions[peer], suggestion.botUserID != fromUserID else { return }
    if let after = suggestion.afterMessageID, messageID <= after { return }
    remove(peer)
  }

  /// The user typed, sent, accepted or dismissed it.
  public func dismiss(peer: Peer) {
    remove(peer)
  }

  private func remove(_ peer: Peer) {
    guard suggestions.removeValue(forKey: peer) != nil else { return }
    subject.send(peer)
  }
}
