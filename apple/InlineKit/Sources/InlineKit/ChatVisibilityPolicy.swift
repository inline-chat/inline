public enum ChatVisibilityPolicy {
  /// Mirrors the server's update-chat-visibility authorization contract.
  public static func canChange(
    chat: Chat?,
    currentUserId: Int64?,
    membership: Member?
  ) -> Bool {
    guard let chat,
          chat.type == .thread,
          let spaceId = chat.spaceId,
          let currentUserId,
          membership?.spaceId == spaceId,
          membership?.userId == currentUserId,
          let role = membership?.role
    else { return false }

    return chat.createdBy == currentUserId || role == .owner || role == .admin
  }
}
