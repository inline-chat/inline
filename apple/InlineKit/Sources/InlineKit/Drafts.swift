import Foundation
import GRDB
import InlineProtocol
import Logger

struct DraftWriteRequestGate {
  private var latestTokenByPeerId: [Peer: UInt64] = [:]
  private var nextToken: UInt64 = 0

  mutating func registerRequest(for peerId: Peer) -> UInt64 {
    nextToken &+= 1
    let token = nextToken
    latestTokenByPeerId[peerId] = token
    return token
  }

  func isLatest(_ token: UInt64, for peerId: Peer) -> Bool {
    latestTokenByPeerId[peerId] == token
  }
}

public struct MessageDraft: Codable, Sendable {
  public var text: String
  public var entities: MessageEntities?

  public init(text: String, entities: MessageEntities?) {
    self.text = text
    self.entities = entities
  }
}

public final class Drafts: @unchecked Sendable {
  private let log = Log.scoped("Drafts")
  private let requestGateQueue = DispatchQueue(label: "chat.inline.Drafts.request-gate")
  private var requestGate = DraftWriteRequestGate()
  public static let shared = Drafts()

  public init() {}

  private func registerRequest(for peerId: Peer) -> UInt64 {
    requestGateQueue.sync {
      requestGate.registerRequest(for: peerId)
    }
  }

  private func isLatestRequest(_ token: UInt64, for peerId: Peer) -> Bool {
    requestGateQueue.sync {
      requestGate.isLatest(token, for: peerId)
    }
  }

  public func update(peerId: Peer, text: String, entities: MessageEntities?) {
    let draft = MessageDraft(text: text, entities: entities)
    let requestToken = registerRequest(for: peerId)

    log.debug("Draft update for peer \(peerId): \(draft)")

    let log = self.log

    Task(priority: .utility) { [self] in
      guard isLatestRequest(requestToken, for: peerId) else {
        log.debug("Skipping stale draft update for peer \(peerId)")
        return
      }

      do {
        try await AppDatabase.shared.dbWriter.write { db in
          guard isLatestRequest(requestToken, for: peerId) else {
            log.debug("Skipping stale draft update in DB write for peer \(peerId)")
            return
          }

          if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) {
            let protocolDraft = InlineProtocol.DraftMessage.with {
              $0.text = draft.text
              if let entities = draft.entities {
                $0.entities = entities
              }
            }
            dialog.draftMessage = protocolDraft
            log.debug("Draft protocol payload for peer \(peerId): \(protocolDraft)")
            try dialog.save(db)
          }
        }
      } catch {
        Log.shared.error("Failed to update draft", error: error)
      }
    }
  }

  public func clear(peerId: Peer) {
    let requestToken = registerRequest(for: peerId)

    Task(priority: .utility) { [self] in
      guard isLatestRequest(requestToken, for: peerId) else {
        log.debug("Skipping stale draft clear for peer \(peerId)")
        return
      }

      do {
        try await AppDatabase.shared.dbWriter.write { db in
          guard isLatestRequest(requestToken, for: peerId) else {
            log.debug("Skipping stale draft clear in DB write for peer \(peerId)")
            return
          }

          if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) {
            dialog.draftMessage = nil
            try dialog.save(db)
          }
        }
      } catch {
        Log.shared.error("Failed to clear draft", error: error)
      }
    }
  }
}
