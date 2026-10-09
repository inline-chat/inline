import InlineKit
import Observation
import SwiftUI

/// Keep responder changes below TabView's content construction. Rebuilding its
/// tab controllers while a field is editing can remove and restore the first
/// responder in a keyboard/layout feedback loop.
@MainActor
@Observable
final class ExperimentalSearchPresentation {
  var query = ""
  var focusRequested = false
  var isFieldFocused = false
  var isKeyboardVisible = false

  var isActive: Bool {
    focusRequested || isFieldFocused || isKeyboardVisible
  }
}

/// The tab's content closure captures a stable presentation reference. Only
/// this child observes the query and responder state used by the search view.
struct ExperimentalSearchTab: View {
  let presentation: ExperimentalSearchPresentation
  let activeSpaceId: Int64?
  let onFocusChanged: (Bool) -> Void
  let onClose: () -> Void
  let onOpenResult: (Peer, Destination) -> Void

  @Environment(Router.self) private var router

  var body: some View {
    @Bindable var presentation = presentation

    ExperimentalSearchView(
      query: $presentation.query,
      focusRequested: $presentation.focusRequested,
      isActivePresentation: router.selectedTab == .search
        && router.selectedTabPath.isEmpty && presentation.isActive,
      activeSpaceId: activeSpaceId,
      onFocusChanged: onFocusChanged,
      onClose: onClose,
      onOpenResult: onOpenResult
    )
  }
}

/// Observe keyboard chrome independently of the root that constructs the tabs.
struct ExperimentalSearchRootChrome: ViewModifier {
  let presentation: ExperimentalSearchPresentation
  let onOpenGrid: () -> Void

  @Environment(Router.self) private var router
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let isActive = router.selectedTab == .search
      && router.selectedTabPath.isEmpty && presentation.isActive

    content
      .toolbarVisibility(isActive ? .hidden : .visible, for: .navigationBar)
      .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isActive)
      .gridHomeEntry(isVisible: !isActive, onOpen: onOpenGrid)
  }
}
