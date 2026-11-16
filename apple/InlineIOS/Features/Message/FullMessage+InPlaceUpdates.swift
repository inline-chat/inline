import InlineKit

/// How a message changed, for the older `UIMessageView`, which applies some changes in place (and
/// animates them) instead of being rebuilt: the send's acknowledgement, acknowledgements, reactions.
/// Shared by the collection view's cell and the timeline's fallback rows.
extension FullMessage {
  /// Only the reactions differ.
  func isReactionOnlyUpdate(to newMessage: FullMessage) -> Bool {
    guard reactions != newMessage.reactions else { return false }
    var currentWithoutReactions = self
    currentWithoutReactions.reactions = []
    var newWithoutReactions = newMessage
    newWithoutReactions.reactions = []
    return currentWithoutReactions == newWithoutReactions
  }

  /// Only the acknowledgements differ.
  func isAcknowledgementOnlyUpdate(to newMessage: FullMessage) -> Bool {
    guard acknowledgements != newMessage.acknowledgements
      || currentUserAcknowledgement != newMessage.currentUserAcknowledgement
    else { return false }
    return withoutAcknowledgements == newMessage.withoutAcknowledgements
  }

  /// The server acknowledged a send: sending became sent, with the server's id.
  func isDeliveryAcknowledgementUpdate(to newMessage: FullMessage) -> Bool {
    guard id == newMessage.id, message.status == .sending, newMessage.message.status == .sent else { return false }
    var acknowledged = self
    acknowledged.message.status = newMessage.message.status
    acknowledged.message.messageId = newMessage.message.messageId
    acknowledged.message.randomId = newMessage.message.randomId
    return acknowledged == newMessage
  }

  /// The reaction whose count changed, to pop it.
  func changedReactionEmoji(to newMessage: FullMessage) -> String? {
    let currentByEmoji = Dictionary(grouping: reactions) { $0.reaction.emoji }
    let newByEmoji = Dictionary(grouping: newMessage.reactions) { $0.reaction.emoji }
    var candidates: [String] = []
    for emoji in newMessage.groupedReactions.map(\.emoji) + groupedReactions.map(\.emoji)
      where !candidates.contains(emoji)
    {
      candidates.append(emoji)
    }
    return candidates.first { currentByEmoji[$0] != newByEmoji[$0] }
  }
}
