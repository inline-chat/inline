import Foundation
import InlineKit
import InlineProtocol
import Logger

@MainActor
public final class DraftManager {
  private static let attachmentMarker = "\u{FFFC}"

  private let log = Log.scoped("DraftManager")
  private let debounceDelay: TimeInterval
  private var saveTask: Task<Void, Never>?
  private var loadedText: String?
  private var loadedEntities: MessageEntities?
  private var lastSavedSnapshot: DraftPersistenceSnapshot?

  public init(debounceDelay: TimeInterval) {
    self.debounceDelay = debounceDelay
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

    saveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: UInt64(debounceDelay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      let snapshot = NSAttributedString(attributedString: currentAttributedString())
      await saveNow(peerId: peerId, attributedString: snapshot)
    }
  }

  public func save(peerId: InlineKit.Peer?, attributedString: NSAttributedString) {
    let snapshot = NSAttributedString(attributedString: attributedString)
    Task { @MainActor [weak self] in
      await self?.saveNow(peerId: peerId, attributedString: snapshot)
    }
  }

  public func saveNow(peerId: InlineKit.Peer?, attributedString: NSAttributedString) async {
    guard let payload = makePayload(peerId: peerId, attributedString: attributedString) else { return }
    await persist(payload)
  }

  public func clear(peerId: InlineKit.Peer?) {
    guard let peerId else { return }

    cancelPendingSave()
    loadedText = nil
    loadedEntities = nil

    let task = Drafts.shared.clear(peerId: peerId)
    Task { @MainActor [weak self] in
      if await task.value {
        self?.lastSavedSnapshot = nil
      }
    }
  }

  public func clearNow(peerId: InlineKit.Peer?) async {
    guard let peerId else { return }

    cancelPendingSave()
    loadedText = nil
    loadedEntities = nil

    do {
      if try await Drafts.shared.clearNow(peerId: peerId) {
        lastSavedSnapshot = nil
      }
    } catch {
      log.error("Failed to clear draft", error: error)
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

  private func persist(_ payload: DraftPersistencePayload) async {
    do {
      switch payload {
        case .clear(let peerId):
          guard lastSavedSnapshot != nil else { return }
          if try await Drafts.shared.clearNow(peerId: peerId) {
            loadedText = nil
            loadedEntities = nil
            lastSavedSnapshot = nil
          }
        case let .update(peerId, text, entities, snapshot):
          if try await Drafts.shared.updateNow(peerId: peerId, text: text, entities: entities) {
            lastSavedSnapshot = snapshot
          }
      }
    } catch {
      log.error("Failed to persist draft", error: error)
    }
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

enum DraftPersistencePayload {
  case clear(peerId: InlineKit.Peer)
  case update(peerId: InlineKit.Peer, text: String, entities: MessageEntities?, snapshot: DraftPersistenceSnapshot)
}
