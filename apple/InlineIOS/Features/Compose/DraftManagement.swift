import InlineKit
import Logger
import UIKit
import InlineProtocol

extension ComposeView {
  func startDraftSaveTimer() {
    stopDraftSaveTimer() // Stop any existing timer
    draftSaveTimer = Timer.scheduledTimer(withTimeInterval: draftSaveInterval, repeats: true) { [weak self] _ in
      self?.saveDraftIfNeeded()
    }
    Log.shared.debug("🌴 Draft auto-save timer started")
  }

  func stopDraftSaveTimer() {
    if draftSaveTimer != nil {
      Log.shared.debug("🌴 Draft auto-save timer stopped")
    }
    draftSaveTimer?.invalidate()
    draftSaveTimer = nil
  }

  func saveDraftIfNeeded() {
    guard let peerId else { return }
    guard let text = textView.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // If text is empty, clear the draft
      Drafts.shared.clear(peerId: peerId)
      originalDraftEntities = nil
      return
    }

    // Extract mention entities from attributed text for draft
    let attributedText = textView.attributedText ?? NSAttributedString()
    let mentionEntities = mentionManager?.extractMentionEntities(from: attributedText) ?? []

    // Determine final entities to save
    let entities: MessageEntities? = if !mentionEntities.isEmpty {
      // We have current mention entities, use them
      MessageEntities.with { $0.entities = mentionEntities }
    } else if let originalEntities = originalDraftEntities {
      // No current mentions but we had original entities, preserve them if they're still valid
      validateAndPreserveEntities(originalEntities, for: text)
    } else {
      // No mentions at all
      nil
    }

    Log.shared.debug("🌴 Auto-saving draft: \(text.prefix(50))...")
    Drafts.shared.update(peerId: peerId, text: text, entities: entities)
  }

  func validateAndPreserveEntities(_ originalEntities: MessageEntities, for text: String) -> MessageEntities? {
    // Validate that the original entities are still within bounds of the current text
    let textLength = text.utf16.count
    let validEntities = originalEntities.entities.filter { entity in
      let endPosition = Int(entity.offset) + Int(entity.length)
      return entity.offset >= 0 && endPosition <= textLength
    }

    if validEntities.isEmpty {
      return nil
    } else {
      return MessageEntities.with { $0.entities = validEntities }
    }
  }

  // MARK: - Draft Management

  func loadDraft(from draftMessage: InlineProtocol.DraftMessage?) {
    guard let draftMessage else { return }

    print("🌴 draftMessage in loadDraft im compose", draftMessage)
    let draft = MessageDraft(
      text: draftMessage.text,
      entities: draftMessage.hasEntities ? draftMessage.entities : nil
    )

    applyDraft(draft.text, entities: draft.entities)
  }

  func applyDraft(_ draft: String?, entities: MessageEntities? = nil) {
    if let draft, !draft.isEmpty {
      textView.text = draft

      // Store original entities for preservation during auto-save
      originalDraftEntities = entities

      if let entities {
        for entity in entities.entities {
          if entity.type == .mention, case let .mention(mention) = entity.entity {
            let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

            if range.location >= 0, range.location + range.length <= draft.utf16.count {
              let attributedText = NSMutableAttributedString(attributedString: textView.attributedText)

              attributedText.addAttributes([
                .foregroundColor: ThemeManager.shared.selected.accent,
                NSAttributedString.Key("mention_user_id"): mention.userID,
              ], range: range)

              textView.attributedText = attributedText
            }
          }
        }
      }

      textView.showPlaceholder(false)
      buttonAppear()
      updateHeight()

      // Start timer since we now have text content
      startDraftSaveTimer()
    }
  }

  /// Set the initial draft from ChatView (call this after setting peerId and chatId)
  public func setInitialDraft(from draftMessage: InlineProtocol.DraftMessage?) {
    guard let draftMessage else { return }

    let draft = MessageDraft(
      text: draftMessage.text,
      entities: draftMessage.hasEntities ? draftMessage.entities : nil
    )

    applyDraft(draft.text, entities: draft.entities)
  }

  func saveDraft() {
    // Use the timer-based save method for consistency
    saveDraftIfNeeded()
  }

  func clearDraft() {
    guard let peerId else { return }
    Drafts.shared.clear(peerId: peerId)
    originalDraftEntities = nil
  }

  @objc func saveCurrentDraft() {
    saveDraft()
  }
}
