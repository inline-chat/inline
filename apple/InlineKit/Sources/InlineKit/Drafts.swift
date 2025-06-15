import Foundation
import GRDB
import InlineProtocol
import Logger

public struct MessageDraft: Codable, Sendable {
  public var text: String
  public var entities: MessageEntities?

  public init(text: String, entities: MessageEntities?) {
    self.text = text
    self.entities = entities
  }
}

public final class Drafts: Sendable {
  private let log = Log.scoped("Drafts")
  public static let shared = Drafts()

  public init() {}

  public func update(peerId: Peer, text: String, entities: MessageEntities?) {
    let draft = MessageDraft(text: text, entities: entities)

    print("🌴 Draft message in update", draft)

    Task {
      do {
        try await AppDatabase.shared.dbWriter.write { db in
          if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) {
            let protocolDraft = InlineProtocol.DraftMessage.with {
              $0.text = draft.text
              if let entities = draft.entities {
                $0.entities = entities
              }
            }
            dialog.draftMessage = protocolDraft
            print("🌴 Draft message in protocolDraft", protocolDraft)
            try dialog.save(db)
          }
        }
      } catch {
        log.error("Failed to update draft", error: error)
      }
    }
  }

  public func clear(peerId: Peer) {
    Task {
      do {
        try await AppDatabase.shared.dbWriter.write { db in
          if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) {
            dialog.draftMessage = nil
            try dialog.save(db)
          }
        }
      } catch {
        log.error("Failed to clear draft", error: error)
      }
    }
  }
}
