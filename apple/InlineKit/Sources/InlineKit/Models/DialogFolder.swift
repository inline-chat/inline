import Foundation
import GRDB
import InlineProtocol

/// A personal, server-synced folder whose children remain ordinary dialogs.
public struct DialogFolder: Codable, FetchableRecord, Identifiable, PersistableRecord,
  Sendable, TableRecord {
  public static let databaseTableName = "dialogFolder"

  public var id: Int64
  public var title: String?
  /// Uses the same fractional ordering coordinate as `Dialog.order`.
  public var order: String
  public var emoji: String?

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let title = Column(CodingKeys.title)
    public static let order = Column(CodingKeys.order)
    public static let emoji = Column(CodingKeys.emoji)
  }

  public static let dialogs = hasMany(Dialog.self)
  public var dialogs: QueryInterfaceRequest<Dialog> {
    request(for: DialogFolder.dialogs)
  }

  public init(id: Int64, title: String?, order: String, emoji: String? = nil) {
    self.id = id
    self.title = title
    self.order = order
    self.emoji = emoji
  }

  public init(from folder: InlineProtocol.DialogFolder) {
    id = folder.id
    title = folder.hasTitle ? folder.title : nil
    order = folder.order
    emoji = folder.hasEmoji ? folder.emoji : nil
  }
}

public extension InlineProtocol.DialogFolder {
  @discardableResult
  func saveFull(_ db: Database) throws -> DialogFolder {
    let model = DialogFolder(from: self)
    try model.save(db, onConflict: .replace)
    return model
  }
}
