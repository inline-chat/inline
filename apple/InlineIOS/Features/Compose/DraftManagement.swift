import InlineKit
import InlineProtocol
import Logger
import TextProcessing
import UIKit

extension ComposeView {
  private static let draftLog = Log.scoped("ComposeView.DraftManagement")

  func startDraftSaveTimer() {
    draftManager.scheduleSave(peerId: peerId) { [weak self] in
      self?.textView.attributedText ?? NSAttributedString()
    }
    Self.draftLog.debug("Draft auto-save scheduled")
  }

  func stopDraftSaveTimer() {
    draftManager.cancelPendingSave()
  }

  func saveDraftIfNeeded() {
    draftManager.save(peerId: peerId, attributedString: textView.attributedText ?? NSAttributedString())
  }

  // MARK: - Draft Management

  func loadDraft(from draftMessage: InlineProtocol.DraftMessage?) {
    guard let draft = draftManager.load(draftMessage) else { return }
    applyDraft(draft.text, entities: draft.entities)
  }

  func applyDraft(_ draft: String?, entities: MessageEntities? = nil) {
    if let draft, !draft.isEmpty {
      textView.text = draft
      draftManager.markLoaded(text: draft, entities: entities)

      if let entities {
        // Use ProcessEntities to apply entities to text
        let attributedText = ProcessEntities.toAttributedString(
          text: draft,
          entities: entities,
          configuration: .init(
            font: textView.font ?? UIFont.systemFont(ofSize: 17),
            textColor: UIColor.label,
            linkColor: ThemeManager.shared.selected.accent,
            convertMentionsToLink: false
          )
        )

        textView.attributedText = attributedText
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
    guard let draft = draftManager.load(draftMessage) else { return }
    applyDraft(draft.text, entities: draft.entities)
  }

  func saveDraft() {
    saveDraftIfNeeded()
  }

  func clearDraft() {
    draftManager.clear(peerId: peerId)
  }

  @objc func saveCurrentDraft() {
    saveDraft()
  }
}
