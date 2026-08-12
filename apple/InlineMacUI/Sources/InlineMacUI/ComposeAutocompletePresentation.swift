import InlineKit

public struct ComposeAutocompletePresentationSession: Equatable, Sendable {
  public let kind: ComposeAutocompleteKind
  public let triggerLocation: Int

  public init(match: ComposeAutocompleteMatch) {
    kind = match.kind
    triggerLocation = match.range.location
  }
}

public enum ComposeAutocompletePresentationAction: Equatable, Sendable {
  case hide
  case retainVisibleContent
  case present
}

public enum ComposeAutocompleteCommitKeyAction: Equatable, Sendable {
  case ignore
  case consume
  case select
}

public func composeAutocompletePresentationAction(
  currentSession: ComposeAutocompletePresentationSession?,
  nextMatch: ComposeAutocompleteMatch?,
  hasItems: Bool,
  loadState: ComposeAutocompleteLoadState,
  isVisible: Bool
) -> ComposeAutocompletePresentationAction {
  guard let nextMatch else { return .hide }
  guard !hasItems else { return .present }

  if loadState == .loading,
     isVisible,
     currentSession == ComposeAutocompletePresentationSession(match: nextMatch) {
    return .retainVisibleContent
  }

  return .hide
}

public func composeAutocompleteCommitKeyAction(
  match: ComposeAutocompleteMatch?,
  loadState: ComposeAutocompleteLoadState,
  isVisible: Bool,
  canSelectItems: Bool
) -> ComposeAutocompleteCommitKeyAction {
  if isVisible {
    return canSelectItems ? .select : .consume
  }

  return match != nil && loadState == .loading ? .consume : .ignore
}
