import AppKit
import Auth
import InlineKit
import InlineMacUI
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

/// Reacting to a message: the quick suggestions and the add/remove toggle. Shared by the reaction
/// overlay and the reactions bar above the message context menu, so both suggest and send the same way.
@MainActor
enum MessageReactionActions {
  private static let log = Log.scoped("MessageReactionActions")

  struct Suggestions {
    /// What to show, skin tone applied, emoji found in the message first.
    var displayed: [String]
    /// The stored emoji behind each displayed one (before the skin tone).
    var sources: [String: String]
    var usageCounts: [String: Int]
    /// Emoji written in the message itself; these are sent exactly as shown.
    var messageEmojis: Set<String>
  }

  static func suggestions(for fullMessage: FullMessage) -> Suggestions {
    let messageText = fullMessage.message.text
    let counts = ReactionPickerEmojiUsageStore.usageCounts()
    var displayed: [String] = []
    var sources: [String: String] = [:]
    for source in ReactionPickerEmojis.suggestions(from: counts) {
      let shown = AppSettings.shared.preferredEmojiSkinTone.applying(to: source)
      guard sources[shown] == nil else { continue }
      sources[shown] = source
      displayed.append(shown)
    }
    return Suggestions(
      displayed: ReactionPickerEmojis.prioritizingMessageEmojis(in: messageText, among: displayed),
      sources: sources,
      usageCounts: counts,
      messageEmojis: Set(ReactionPickerEmojis.prioritizingMessageEmojis(in: messageText, among: []))
    )
  }

  /// Emoji the current user already reacted with on this message.
  static func chosenEmojis(on fullMessage: FullMessage) -> Set<String> {
    guard let userId = Auth.shared.getCurrentUserId() else { return [] }
    return Set(fullMessage.reactions.filter { $0.reaction.userId == userId }.map(\.reaction.emoji))
  }

  /// Adds the reaction, or removes it when the user already reacted with it.
  /// - Returns: false when nothing was sent (no signed-in user, or not an emoji).
  @discardableResult
  static func toggle(_ emoji: String, on fullMessage: FullMessage, messageEmojis: Set<String>) -> Bool {
    // Emoji from the message are already validated and must be sent exactly as displayed.
    let selected = messageEmojis.contains(emoji) ? emoji : EmojiPickerValue.normalizedEmoji(from: emoji)
    guard let emoji = selected, let userId = Auth.shared.getCurrentUserId() else { return false }
    let hasReaction = fullMessage.reactions.contains {
      $0.reaction.emoji == emoji && $0.reaction.userId == userId
    }
    Task(priority: .userInitiated) { @MainActor in
      do {
        if hasReaction {
          try await Api.realtime.send(.deleteReaction(emoji: emoji, message: fullMessage.message))
        } else {
          try await Api.realtime.send(.addReaction(emoji: emoji, message: fullMessage.message))
          ReactionPickerEmojiUsageStore.recordPick(emoji)
        }
      } catch {
        log.error("Failed to update reaction", error: error)
      }
    }
    return true
  }

  /// Where the reactions bar sits: 10 pt above the menu, its trailing edge past the menu's, as
  /// Telegram macOS places its reactions over its menu.
  static let contextMenuAccessoryConfiguration = ContextMenuAccessoryConfiguration(
    location: .above,
    alignment: .trailing,
    spacing: 10,
    offset: 30
  )

  /// The reactions bar for a message's context menu: the same strip as the reaction overlay, on the
  /// menu's glass. + closes the menu and opens the full picker from the bar, where it is.
  static func contextMenuAccessory(for fullMessage: FullMessage) -> NSView {
    MessageReactionAccessoryView(fullMessage: fullMessage)
  }
}
