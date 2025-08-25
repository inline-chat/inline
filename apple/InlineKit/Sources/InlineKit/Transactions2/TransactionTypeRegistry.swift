import Foundation
import RealtimeV2

/// Registry for mapping between transaction types and their string representations
/// Used for serialization/deserialization in persistence layer
public enum TransactionTypeRegistry {
  
  /// Convert a transaction instance to its string type identifier
  public static func typeString(for transaction: any Transaction2) -> String {
    switch transaction {
      case is SendMessageTransaction: return "send_message"
      case is AddReactionTransaction: return "add_reaction"
      case is DeleteReactionTransaction: return "delete_reaction"
      case is EditMessageTransaction: return "edit_message"
      case is DeleteMessageTransaction: return "delete_message"
      case is CreateChatTransaction: return "create_chat"
      case is GetMeTransaction: return "get_me"
      case is GetSpaceMembersTransaction: return "get_space_members"
      case is InviteToSpaceTransaction: return "invite_to_space"
      case is DeleteChatTransaction: return "delete_chat"
      default: return "unknown"
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
      case "get_me": return try decoder.decode(GetMeTransaction.self, from: data)
      case "get_space_members": return try decoder.decode(GetSpaceMembersTransaction.self, from: data)
      case "invite_to_space": return try decoder.decode(InviteToSpaceTransaction.self, from: data)
      case "delete_chat": return try decoder.decode(DeleteChatTransaction.self, from: data)
      default: throw TransactionTypeError.unknownTransactionType(type)
    }
  }
}

// MARK: - Errors

public enum TransactionTypeError: Error {
  case unknownTransactionType(String)
}