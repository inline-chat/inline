import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateDialogFolderTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .createDialogFolder
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let title: String?
    let peers: [Peer]
    let order: String?
  }

  public init(title: String?, peers: [Peer], order: String? = nil) {
    context = Context(title: title, peers: peers, order: order)
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createDialogFolder(.with {
      if let title = context.title { $0.title = title }
      $0.peers = context.peers.map { $0.toInputPeer() }
      if let order = context.order { $0.order = order }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .createDialogFolder(response) = result, response.hasFolder else {
      throw TransactionExecutionError.invalid
    }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try response.folder.saveFull(db)
        for dialog in response.dialogs { try dialog.saveFull(db) }
      }
    } catch {
      Log.scoped("Transactions/CreateDialogFolder").error("Failed to save dialog folder", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct UpdateDialogFolderTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updateDialogFolder
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public enum TitleUpdate: Sendable, Codable {
    case unchanged
    case set(String)
    case clear
  }

  public enum EmojiUpdate: Sendable, Codable {
    case unchanged
    case set(String)
    case clear
  }

  public struct Context: Sendable, Codable {
    let folderId: Int64
    let title: TitleUpdate
    /// Optional so transactions queued by older app versions still decode.
    let emoji: EmojiUpdate?
    let order: String?
  }

  public init(
    folderId: Int64,
    title: TitleUpdate = .unchanged,
    emoji: EmojiUpdate = .unchanged,
    order: String? = nil
  ) {
    context = Context(folderId: folderId, title: title, emoji: emoji, order: order)
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogFolder(.with {
      $0.folderID = context.folderId
      switch context.title {
      case .unchanged: break
      case let .set(title): $0.title = title
      case .clear: $0.clearTitle_p = true
      }
      switch context.emoji ?? .unchanged {
      case .unchanged: break
      case let .set(emoji): $0.emoji = emoji
      case .clear: $0.clearEmoji_p = true
      }
      if let order = context.order { $0.order = order }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogFolder(response) = result, response.hasFolder else {
      throw TransactionExecutionError.invalid
    }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try response.folder.saveFull(db)
        for dialog in response.dialogs { try dialog.saveFull(db) }
      }
    } catch {
      Log.scoped("Transactions/UpdateDialogFolder").error("Failed to save dialog folder", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct DeleteDialogFolderTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .deleteDialogFolder
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public enum Disposition: String, Sendable, Codable {
    case closeDialogs
    case keepDialogs
  }

  public struct Context: Sendable, Codable {
    let folderId: Int64
    let disposition: Disposition
  }

  public init(folderId: Int64, disposition: Disposition) {
    context = Context(folderId: folderId, disposition: disposition)
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteDialogFolder(.with {
      $0.folderID = context.folderId
      $0.disposition = context.disposition == .closeDialogs ? .closeDialogs : .keepDialogs
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .deleteDialogFolder(response) = result, response.folderID == context.folderId else {
      throw TransactionExecutionError.invalid
    }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        for dialog in response.dialogs { try dialog.saveFull(db) }
        try DialogFolder.deleteOne(db, key: response.folderID)
      }
    } catch {
      Log.scoped("Transactions/DeleteDialogFolder").error("Failed to remove dialog folder", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == CreateDialogFolderTransaction {
  static func createDialogFolder(
    title: String?,
    peers: [Peer],
    order: String? = nil
  ) -> CreateDialogFolderTransaction {
    CreateDialogFolderTransaction(title: title, peers: peers, order: order)
  }
}

public extension Transaction2 where Self == UpdateDialogFolderTransaction {
  static func updateDialogFolder(
    folderId: Int64,
    title: UpdateDialogFolderTransaction.TitleUpdate = .unchanged,
    emoji: UpdateDialogFolderTransaction.EmojiUpdate = .unchanged,
    order: String? = nil
  ) -> UpdateDialogFolderTransaction {
    UpdateDialogFolderTransaction(folderId: folderId, title: title, emoji: emoji, order: order)
  }
}

public extension Transaction2 where Self == DeleteDialogFolderTransaction {
  static func deleteDialogFolder(
    folderId: Int64,
    disposition: DeleteDialogFolderTransaction.Disposition
  ) -> DeleteDialogFolderTransaction {
    DeleteDialogFolderTransaction(folderId: folderId, disposition: disposition)
  }
}
