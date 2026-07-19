import Foundation
import GRDB
import InlineProtocol
import Logger

public enum DraftWriteIntentKind: Equatable, Sendable {
  case update
  case clear
}

public struct DraftWriteIntent: Equatable, Sendable {
  public let peerId: Peer
  public let kind: DraftWriteIntentKind
  fileprivate let token: UInt64
}

struct DraftWriteRequestGate {
  private var latestTokenByPeerId: [Peer: UInt64] = [:]
  private var latestKindByPeerId: [Peer: DraftWriteIntentKind] = [:]
  private var suppressesRestorationByPeerId: [Peer: Bool] = [:]
  private var nextToken: UInt64 = 0

  mutating func registerRequest(
    for peerId: Peer,
    kind: DraftWriteIntentKind = .update
  ) -> UInt64 {
    nextToken &+= 1
    let token = nextToken
    latestTokenByPeerId[peerId] = token
    latestKindByPeerId[peerId] = kind
    if kind == .clear {
      suppressesRestorationByPeerId[peerId] = true
    }
    return token
  }

  func isLatest(_ token: UInt64, for peerId: Peer) -> Bool {
    latestTokenByPeerId[peerId] == token
  }

  func latestKind(for peerId: Peer) -> DraftWriteIntentKind? {
    latestKindByPeerId[peerId]
  }

  mutating func markPersisted(_ token: UInt64, for peerId: Peer) {
    guard isLatest(token, for: peerId) else { return }
    if latestKindByPeerId[peerId] == .update {
      suppressesRestorationByPeerId[peerId] = false
    }
  }

  func shouldSuppressRestoration(for peerId: Peer) -> Bool {
    suppressesRestorationByPeerId[peerId] == true
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

  public func registerIntent(
    for peerId: Peer,
    kind: DraftWriteIntentKind
  ) -> DraftWriteIntent {
    requestGateQueue.sync {
      DraftWriteIntent(
        peerId: peerId,
        kind: kind,
        token: requestGate.registerRequest(for: peerId, kind: kind)
      )
    }
  }

  public func isLatestIntent(_ intent: DraftWriteIntent) -> Bool {
    requestGateQueue.sync {
      requestGate.isLatest(intent.token, for: intent.peerId)
    }
  }

  public func shouldSuppressDraftRestoration(for peerId: Peer) -> Bool {
    requestGateQueue.sync {
      requestGate.shouldSuppressRestoration(for: peerId)
    }
  }

  private func markIntentPersisted(_ intent: DraftWriteIntent) {
    requestGateQueue.sync {
      requestGate.markPersisted(intent.token, for: intent.peerId)
    }
  }

  @discardableResult
  public func update(peerId: Peer, text: String, entities: MessageEntities?) -> Task<Bool, Never> {
    let intent = registerIntent(for: peerId, kind: .update)
    return update(peerId: peerId, text: text, entities: entities, intent: intent)
  }

  @discardableResult
  private func update(
    peerId: Peer,
    text: String,
    entities: MessageEntities?,
    intent: DraftWriteIntent
  ) -> Task<Bool, Never> {
    Task(priority: .utility) { [self] in
      do {
        return try await updateNow(
          peerId: peerId,
          text: text,
          entities: entities,
          intent: intent
        )
      } catch {
        Log.shared.error("Failed to update draft", error: error)
        return false
      }
    }
  }

  @discardableResult
  public func clear(peerId: Peer) -> Task<Bool, Never> {
    let intent = registerIntent(for: peerId, kind: .clear)
    return clear(peerId: peerId, intent: intent)
  }

  @discardableResult
  private func clear(
    peerId: Peer,
    intent: DraftWriteIntent
  ) -> Task<Bool, Never> {
    Task(priority: .utility) { [self] in
      do {
        return try await clearNow(peerId: peerId, intent: intent)
      } catch {
        Log.shared.error("Failed to clear draft", error: error)
        return false
      }
    }
  }

  @discardableResult
  public func updateNow(peerId: Peer, text: String, entities: MessageEntities?) async throws -> Bool {
    let intent = registerIntent(for: peerId, kind: .update)
    return try await updateNow(
      peerId: peerId,
      text: text,
      entities: entities,
      intent: intent
    )
  }

  @discardableResult
  public func updateNow(
    peerId: Peer,
    text: String,
    entities: MessageEntities?,
    intent: DraftWriteIntent
  ) async throws -> Bool {
    guard intent.peerId == peerId, intent.kind == .update else {
      log.error("Skipping draft update with mismatched intent for peer \(peerId)")
      return false
    }

    let entities = normalizedEntities(entities)
    let draft = MessageDraft(text: text, entities: entities)

    log.debug(
      "Draft update requested for peer \(peerId), length=\(draft.text.utf16.count), entities=\(draft.entities?.entities.count ?? 0)"
    )

    guard isLatestIntent(intent) else {
      log.debug("Skipping stale draft update for peer \(peerId)")
      return false
    }

    let didUpdate = try await AppDatabase.shared.dbWriter.write { db in
      guard isLatestIntent(intent) else {
        log.debug("Skipping stale draft update in DB write for peer \(peerId)")
        return false
      }

      guard var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) else {
        log.warning("Skipping draft update because dialog is missing for peer \(peerId)")
        return false
      }

      let protocolDraft = InlineProtocol.DraftMessage.with {
        $0.text = draft.text
        if let entities = draft.entities {
          $0.entities = entities
        }
      }
      dialog.draftMessage = protocolDraft
      try dialog.save(db)
      return true
    }
    if didUpdate {
      markIntentPersisted(intent)
    }
    return didUpdate
  }

  @discardableResult
  public func clearNow(peerId: Peer) async throws -> Bool {
    let intent = registerIntent(for: peerId, kind: .clear)
    return try await clearNow(peerId: peerId, intent: intent)
  }

  @discardableResult
  public func clearNow(
    peerId: Peer,
    intent: DraftWriteIntent
  ) async throws -> Bool {
    guard intent.peerId == peerId, intent.kind == .clear else {
      log.error("Skipping draft clear with mismatched intent for peer \(peerId)")
      return false
    }

    guard isLatestIntent(intent) else {
      log.debug("Skipping stale draft clear for peer \(peerId)")
      return false
    }

    return try await AppDatabase.shared.dbWriter.write { db in
      guard isLatestIntent(intent) else {
        log.debug("Skipping stale draft clear in DB write for peer \(peerId)")
        return false
      }

      guard var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId)) else {
        log.warning("Skipping draft clear because dialog is missing for peer \(peerId)")
        return false
      }

      dialog.draftMessage = nil
      try dialog.save(db)
      return true
    }
  }

  private func normalizedEntities(_ entities: MessageEntities?) -> MessageEntities? {
    guard let entities, !entities.entities.isEmpty else { return nil }
    return entities
  }
}
