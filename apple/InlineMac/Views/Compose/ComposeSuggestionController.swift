import Combine
import InlineKit

/// Shows a bot's suggested next message as the composer's gray placeholder and
/// inserts it on Tab. Shared by the glass and legacy composers so they behave
/// alike; each forwards its empty-state, Tab and Escape events here.
@MainActor
final class ComposeSuggestionController {
  private let peer: Peer
  private weak var editor: ComposeTextEditor?
  private var cancellable: AnyCancellable?

  /// While editing a sent message the suggestion stays hidden.
  var isSuppressed = false {
    didSet {
      guard isSuppressed != oldValue else { return }
      refresh()
    }
  }

  init(peer: Peer, editor: ComposeTextEditor) {
    self.peer = peer
    self.editor = editor
    cancellable = ComposeSuggestions.shared.changes
      .filter { $0 == peer }
      .sink { [weak self] _ in self?.refresh() }
    // A suggestion already in memory shows on the first frame.
    refresh()
  }

  private var shown: String? {
    editor?.suggestionText
  }

  func refresh() {
    editor?.suggestionText = isSuppressed ? nil : ComposeSuggestions.shared.suggestion(for: peer)?.text
  }

  /// Typing ends the suggestion, like Claude Code and the Codex app.
  func textDidChange(isEmpty: Bool) {
    guard !isEmpty, shown != nil else { return }
    ComposeSuggestions.shared.dismiss(peer: peer)
  }

  /// Tab on an empty editor: puts the suggestion in it to edit and send.
  func accept(isEmpty: Bool, insert: (String) -> Void) -> Bool {
    guard isEmpty, let text = shown else { return false }
    ComposeSuggestions.shared.dismiss(peer: peer)
    insert(text)
    return true
  }

  /// Escape on an empty editor dismisses the suggestion.
  func dismiss(isEmpty: Bool) -> Bool {
    guard isEmpty, shown != nil else { return false }
    ComposeSuggestions.shared.dismiss(peer: peer)
    return true
  }
}
