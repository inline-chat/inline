public enum ChatParticipantPolicy {
  /// Mirrors `ensureCanAddChatParticipants` on the server: anyone who can see a
  /// private thread may add people to it. Callers only reach this with chats
  /// the current user can already read.
  public static func canAdd(chat: Chat?) -> Bool {
    guard let chat, chat.type == .thread else { return false }
    return chat.isPublic != true
  }

  /// Mirrors `ensureCanManageChatParticipants` on the server: removal (and so an
  /// add's Undo) stays with the thread's creator and, in a space, its owners and
  /// admins.
  public static func canRemove(chat: Chat?, currentUserId: Int64?, membership: Member?) -> Bool {
    guard let chat, chat.type == .thread, let currentUserId else { return false }
    if chat.createdBy == currentUserId { return true }
    guard let spaceId = chat.spaceId,
          membership?.spaceId == spaceId,
          membership?.userId == currentUserId
    else { return false }
    return membership?.role == .owner || membership?.role == .admin
  }
}
