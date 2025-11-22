import Foundation
import RealtimeV2

/// Registry for mapping between transaction types and their string representations
/// Used for serialization/deserialization in persistence layer
public enum TransactionTypeRegistry {
  /// Convert a transaction instance to its string type identifier
  public static func typeString(for transaction: any Transaction2) -> String {
    switch transaction {
      case is SendMessageTransaction: "send_message"
      case is AddReactionTransaction: "add_reaction"
      case is DeleteReactionTransaction: "delete_reaction"
      case is EditMessageTransaction: "edit_message"
      case is DeleteMessageTransaction: "delete_message"
      case is CreateChatTransaction: "create_chat"
      case is GetChatTransaction: "get_chat"
      case is GetMeTransaction: "get_me"
      case is GetSpaceMembersTransaction: "get_space_members"
      case is InviteToSpaceTransaction: "invite_to_space"
      case is DeleteChatTransaction: "delete_chat"
      case is GetChatParticipantsTransaction: "get_chat_participants"
      case is AddChatParticipantTransaction: "add_chat_participant"
      case is RemoveChatParticipantTransaction: "remove_chat_participant"
      case is TranslateMessagesTransaction: "translate_messages"
      case is UpdateUserSettingsTransaction: "update_user_settings"
      case is MarkAsUnreadTransaction: "mark_as_unread"
      case is DeleteMemberTransaction: "delete_member"
      default: "unknown"
    }
  }

  /// Decode a transaction from its type string and JSON data
  public static func decodeTransaction(type: String, data: Data) throws -> any Transaction2 {
    let decoder = JSONDecoder()
    switch type {
      case "send_message": return try decoder.decode(SendMessageTransaction.self, from: data)
      case "add_reaction": return try decoder.decode(AddReactionTransaction.self, from: data)
      case "delete_reaction": return try decoder.decode(DeleteReactionTransaction.self, from: data)
      case "edit_message": return try decoder.decode(EditMessageTransaction.self, from: data)
      case "delete_message": return try decoder.decode(DeleteMessageTransaction.self, from: data)
      case "create_chat": return try decoder.decode(CreateChatTransaction.self, from: data)
      case "get_chat": return try decoder.decode(GetChatTransaction.self, from: data)
      case "get_me": return try decoder.decode(GetMeTransaction.self, from: data)
      case "get_space_members": return try decoder.decode(GetSpaceMembersTransaction.self, from: data)
      case "invite_to_space": return try decoder.decode(InviteToSpaceTransaction.self, from: data)
      case "delete_chat": return try decoder.decode(DeleteChatTransaction.self, from: data)
      case "get_chat_participants": return try decoder.decode(GetChatParticipantsTransaction.self, from: data)
      case "add_chat_participant": return try decoder.decode(AddChatParticipantTransaction.self, from: data)
      case "remove_chat_participant": return try decoder.decode(RemoveChatParticipantTransaction.self, from: data)
      case "translate_messages": return try decoder.decode(TranslateMessagesTransaction.self, from: data)
      case "update_user_settings": return try decoder.decode(UpdateUserSettingsTransaction.self, from: data)
      case "mark_as_unread": return try decoder.decode(MarkAsUnreadTransaction.self, from: data)
      case "delete_member": return try decoder.decode(DeleteMemberTransaction.self, from: data)
      default: throw TransactionTypeError.unknownTransactionType(type)
    }
  }
}

// MARK: - Errors

public enum TransactionTypeError: Error {
  case unknownTransactionType(String)
}
