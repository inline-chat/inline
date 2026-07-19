import Foundation
import InlineKit
import InlineProtocol
import Logger

struct DraftPersistenceClient: Sendable {
  let registerIntent: @Sendable (InlineKit.Peer, DraftWriteIntentKind) -> DraftWriteIntent
  let isLatestIntent: @Sendable (DraftWriteIntent) -> Bool
  let update: @Sendable (
    InlineKit.Peer,
    String,
    MessageEntities?,
    DraftWriteIntent
  ) async throws -> Bool
  let clear: @Sendable (InlineKit.Peer, DraftWriteIntent) async throws -> Bool

  static let live = DraftPersistenceClient(
    registerIntent: { peerId, kind in
      Drafts.shared.registerIntent(for: peerId, kind: kind)
    },
    isLatestIntent: { intent in
      Drafts.shared.isLatestIntent(intent)
    },
    update: { peerId, text, entities, intent in
      try await Drafts.shared.updateNow(
        peerId: peerId,
        text: text,
        entities: entities,
        intent: intent
      )
    },
    clear: { peerId, intent in
      try await Drafts.shared.clearNow(peerId: peerId, intent: intent)
    }
  )
}

@MainActor
public final class DraftManager {
  private static let attachmentMarker = "\u{FFFC}"

  private let log = Log.scoped("DraftManager")
  private let debounceDelay: TimeInterval
  private let persistence: DraftPersistenceClient
  private var saveTask: Task<Void, Never>?
  private var persistenceTask: Task<Void, Never>?
  private var pendingPersistence: DraftPendingPersistence?
  private var inFlightPersistence: DraftPendingPersistence?
  private var completedPersistence: DraftPendingPersistence?
  private var loadedText: String?
  private var loadedEntities: MessageEntities?
  private var lastSavedSnapshot: DraftPersistenceSnapshot?
  private var latestContentIntent: DraftWriteIntent?

  public init(debounceDelay: TimeInterval) {
    self.debounceDelay = debounceDelay
    persistence = .live
  }

  init(
    debounceDelay: TimeInterval,
    persistence: DraftPersistenceClient
  ) {
    self.debounceDelay = debounceDelay
    self.persistence = persistence
  }

  deinit {
    saveTask?.cancel()
  }

  public func load(_ draftMessage: InlineProtocol.DraftMessage?) -> MessageDraft? {
    guard let draftMessage, !draftMessage.text.isEmpty else { return nil }

    let entities = draftMessage.hasEntities ? normalizedEntities(draftMessage.entities) : nil
    let draft = MessageDraft(text: draftMessage.text, entities: entities)
    markLoaded(text: draft.text, entities: draft.entities)
    return draft
  }

  public func markLoaded(text: String, entities: MessageEntities?) {
    loadedText = text
    loadedEntities = normalizedEntities(entities)
    lastSavedSnapshot = makeSnapshot(text: text, entities: loadedEntities)
  }

  public func invalidateLoadedEntities() {
    loadedEntities = nil
  }

  public func invalidateLoadedEntities(overlapping range: NSRange) {
    guard let loadedEntities else { return }

    let overlapsLoadedEntity = loadedEntities.entities.contains { entity in
      let entityRange = NSRange(location: Int(entity.offset), length: Int(entity.length))
      if range.length == 0 {
        return range.location > entityRange.location && range.location < NSMaxRange(entityRange)
      }
      return NSIntersectionRange(range, entityRange).length > 0
    }
    if overlapsLoadedEntity {
      self.loadedEntities = nil
    }
  }

  public func cancelPendingSave() {
    saveTask?.cancel()
    saveTask = nil
  }

  public func scheduleSave(peerId: InlineKit.Peer?, attributedString: NSAttributedString) {
    let snapshot = NSAttributedString(attributedString: attributedString)
    scheduleSave(peerId: peerId) {
      snapshot
    }
  }

  public func scheduleSave(
    peerId: InlineKit.Peer?,
    currentAttributedString: @escaping @MainActor () -> NSAttributedString
  ) {
    cancelPendingSave()
    guard let peerId else { return }

    let supersedesClearOrExternalIntent = if let latestContentIntent {
      latestContentIntent.kind == .clear ||
        !persistence.isLatestIntent(latestContentIntent)
    } else {
      false
    }
    let intent = persistence.registerIntent(peerId, .update)
    if supersedesClearOrExternalIntent {
      lastSavedSnapshot = nil
    }
    latestContentIntent = intent
    saveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      let snapshot = NSAttributedString(attributedString: currentAttributedString())
      enqueueSave(
        peerId: peerId,
        attributedString: snapshot,
        intent: intent
      )
    }
  }

  public func save(peerId: InlineKit.Peer?, attributedString: NSAttributedString) {
    let snapshot = NSAttributedString(attributedString: attributedString)
    guard let payload = makePayload(peerId: peerId, attributedString: snapshot),
          let intent = currentPersistenceIntent(for: payload)
    else { return }

    enqueuePersistence(payload, intent: intent)
  }

  public func saveNow(peerId: InlineKit.Peer?, attributedString: NSAttributedString) async {
    guard let payload = makePayload(peerId: peerId, attributedString: attributedString) else { return }
    guard let intent = currentPersistenceIntent(for: payload) else { return }
    enqueuePersistence(payload, intent: intent)
    await waitForPersistenceWorker()
  }

  public func clear(peerId: InlineKit.Peer?) {
    guard let peerId else { return }
    enqueueClear(peerId: peerId)
  }

  public func clearNow(peerId: InlineKit.Peer?) async {
    guard let peerId else { return }
    enqueueClear(peerId: peerId)
    await waitForPersistenceWorker()
  }

  func waitForPendingPersistence() async {
    await saveTask?.value
    await waitForPersistenceWorker()
  }

  func waitForPersistenceWorker() async {
    while let persistenceTask {
      await persistenceTask.value
    }
  }

  func makePayload(peerId: InlineKit.Peer?, attributedString: NSAttributedString) -> DraftPersistencePayload? {
    guard let peerId else { return nil }

    let (rawText, extractedEntities) = ProcessEntities.fromAttributedString(attributedString, parseMarkdown: false)
    let text = rawText.replacingOccurrences(of: Self.attachmentMarker, with: "")

    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .clear(peerId: peerId)
    }

    let entities = entitiesForSave(
      rawText: rawText,
      text: text,
      extractedEntities: extractedEntities
    )
    let snapshot = makeSnapshot(text: text, entities: entities)
    guard snapshot != lastSavedSnapshot else { return nil }

    return .update(peerId: peerId, text: text, entities: entities, snapshot: snapshot)
  }

  private func enqueueSave(
    peerId: InlineKit.Peer,
    attributedString: NSAttributedString,
    intent: DraftWriteIntent
  ) {
    guard !Task.isCancelled, persistence.isLatestIntent(intent) else { return }
    guard let payload = makePayload(peerId: peerId, attributedString: attributedString) else { return }
    enqueuePersistence(payload, intent: intent)
  }

  private func enqueueClear(peerId: InlineKit.Peer) {
    cancelPendingSave()
    loadedText = nil
    loadedEntities = nil

    let intent: DraftWriteIntent
    if let latestContentIntent,
       latestContentIntent.peerId == peerId,
       latestContentIntent.kind == .clear,
       persistence.isLatestIntent(latestContentIntent) {
      intent = latestContentIntent
    } else {
      intent = persistence.registerIntent(peerId, .clear)
    }
    latestContentIntent = intent
    enqueuePersistence(.clear(peerId: peerId), intent: intent)
  }

  private func currentPersistenceIntent(
    for payload: DraftPersistencePayload
  ) -> DraftWriteIntent? {
    guard let latestContentIntent,
          latestContentIntent.peerId == payload.peerId,
          latestContentIntent.kind == payload.intentKind,
          persistence.isLatestIntent(latestContentIntent)
    else {
      return nil
    }
    return latestContentIntent
  }

  private func enqueuePersistence(
    _ payload: DraftPersistencePayload,
    intent: DraftWriteIntent
  ) {
    let operation = DraftPendingPersistence(payload: payload, intent: intent)
    guard operation != pendingPersistence else { return }

    // The database already contains this operation unless another write is in flight.
    // If a different pending operation exists, discard it because this is the latest
    // local snapshot. While a write is in flight, retain this as the one follow-up:
    // success will coalesce it, while failure will retry it.
    if operation == completedPersistence, inFlightPersistence == nil {
      pendingPersistence = nil
      return
    }

    pendingPersistence = operation
    guard persistenceTask == nil else { return }

    persistenceTask = Task { @MainActor [self] in
      while let operation = pendingPersistence {
        pendingPersistence = nil
        inFlightPersistence = operation
        if await persist(operation.payload, intent: operation.intent) {
          completedPersistence = operation
          if pendingPersistence == operation {
            pendingPersistence = nil
          }
        }
        inFlightPersistence = nil
      }
      persistenceTask = nil
    }
  }

  private func persist(
    _ payload: DraftPersistencePayload,
    intent: DraftWriteIntent
  ) async -> Bool {
    guard !Task.isCancelled, persistence.isLatestIntent(intent) else { return false }

    do {
      switch payload {
      case .clear(let peerId):
        if try await persistence.clear(peerId, intent),
           persistence.isLatestIntent(intent) {
          loadedText = nil
          loadedEntities = nil
          lastSavedSnapshot = nil
          return true
        }
      case let .update(peerId, text, entities, snapshot):
        if try await persistence.update(peerId, text, entities, intent),
           persistence.isLatestIntent(intent) {
          lastSavedSnapshot = snapshot
          return true
        }
      }
    } catch {
      log.error("Failed to persist draft", error: error)
    }
    return false
  }

  private func entitiesForSave(
    rawText: String,
    text: String,
    extractedEntities: MessageEntities
  ) -> MessageEntities? {
    if rawText == text, let entities = normalizedEntities(extractedEntities) {
      return entities
    }

    guard rawText == text,
          let loadedEntities
    else {
      return nil
    }

    return validate(loadedEntities, for: text)
  }

  private func validate(_ entities: MessageEntities, for text: String) -> MessageEntities? {
    let textLength = text.utf16.count
    let validEntities = entities.entities.filter { entity in
      let end = Int(entity.offset) + Int(entity.length)
      return entity.offset >= 0 && end <= textLength
    }

    guard !validEntities.isEmpty else { return nil }
    return MessageEntities.with { $0.entities = validEntities }
  }

  private func normalizedEntities(_ entities: MessageEntities?) -> MessageEntities? {
    guard let entities, !entities.entities.isEmpty else { return nil }
    return entities
  }

  private func makeSnapshot(text: String, entities: MessageEntities?) -> DraftPersistenceSnapshot {
    let entitiesData: Data?
    if let entities = normalizedEntities(entities) {
      entitiesData = try? entities.serializedData()
    } else {
      entitiesData = nil
    }

    return DraftPersistenceSnapshot(text: text, entitiesData: entitiesData)
  }
}

struct DraftPersistenceSnapshot: Equatable, Sendable {
  let text: String
  let entitiesData: Data?
}

enum DraftPersistencePayload: Equatable {
  case clear(peerId: InlineKit.Peer)
  case update(peerId: InlineKit.Peer, text: String, entities: MessageEntities?, snapshot: DraftPersistenceSnapshot)

  var peerId: InlineKit.Peer {
    switch self {
    case let .clear(peerId), let .update(peerId, _, _, _):
      peerId
    }
  }

  var intentKind: DraftWriteIntentKind {
    switch self {
    case .clear:
      .clear
    case .update:
      .update
    }
  }
}

private struct DraftPendingPersistence: Equatable {
  let payload: DraftPersistencePayload
  let intent: DraftWriteIntent
}
