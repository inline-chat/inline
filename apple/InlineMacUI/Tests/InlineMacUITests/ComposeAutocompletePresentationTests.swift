import Foundation
import InlineKit
@testable import InlineMacUI
import Testing

@Suite("Compose autocomplete presentation")
struct ComposeAutocompletePresentationTests {
  @Test("same trigger retains visible rows while refreshed results load")
  func sameTriggerRetainsVisibleRowsWhileLoading() {
    let original = match(location: 10, query: "w")
    let refined = match(location: 10, query: "wi")

    #expect(
      action(
        current: original,
        next: refined,
        hasItems: false,
        loadState: .loading,
        isVisible: true
      ) == .retainVisibleContent
    )
  }

  @Test("a different trigger cannot retain stale rows")
  func differentTriggerHidesStaleRows() {
    #expect(
      action(
        current: match(location: 10, query: "w"),
        next: match(location: 24, query: "w"),
        hasItems: false,
        loadState: .loading,
        isVisible: true
      ) == .hide
    )
  }

  @Test("loaded rows present and terminal empty results hide")
  func loadedAndTerminalStates() {
    let match = match(location: 10, query: "wish")

    #expect(
      action(
        current: match,
        next: match,
        hasItems: true,
        loadState: .loading,
        isVisible: true
      ) == .present
    )
    #expect(
      action(
        current: match,
        next: match,
        hasItems: false,
        loadState: .idle,
        isVisible: true
      ) == .hide
    )
  }

  @Test("commit keys stay owned during initial and retained loading")
  func loadingOwnsCommitKeys() {
    let match = match(location: 10, query: "wish")

    #expect(commitAction(match: match, loadState: .loading) == .consume)
    #expect(
      commitAction(
        match: match,
        loadState: .loading,
        isVisible: true,
        canSelectItems: false
      ) == .consume
    )
    #expect(
      commitAction(
        match: match,
        loadState: .idle,
        isVisible: true,
        canSelectItems: true
      ) == .select
    )
    #expect(commitAction(match: match, loadState: .idle) == .ignore)
  }

  private func action(
    current: ComposeAutocompleteMatch?,
    next: ComposeAutocompleteMatch?,
    hasItems: Bool,
    loadState: ComposeAutocompleteLoadState,
    isVisible: Bool
  ) -> ComposeAutocompletePresentationAction {
    composeAutocompletePresentationAction(
      currentSession: current.map { ComposeAutocompletePresentationSession(match: $0) },
      nextMatch: next,
      hasItems: hasItems,
      loadState: loadState,
      isVisible: isVisible
    )
  }

  private func match(location: Int, query: String) -> ComposeAutocompleteMatch {
    ComposeAutocompleteMatch(
      kind: .thread,
      range: NSRange(location: location, length: query.utf16.count + 2),
      query: query
    )
  }

  private func commitAction(
    match: ComposeAutocompleteMatch?,
    loadState: ComposeAutocompleteLoadState,
    isVisible: Bool = false,
    canSelectItems: Bool = false
  ) -> ComposeAutocompleteCommitKeyAction {
    composeAutocompleteCommitKeyAction(
      match: match,
      loadState: loadState,
      isVisible: isVisible,
      canSelectItems: canSelectItems
    )
  }
}
