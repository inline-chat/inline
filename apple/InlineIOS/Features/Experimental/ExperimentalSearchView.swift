import InlineKit
import InlineSearch
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct ExperimentalSearchView: View {
  @Binding private var query: String
  @Binding private var focusRequested: Bool
  @Binding private var interactionRevision: Int
  let isActivePresentation: Bool
  let activeSpaceId: Int64?
  let onFocusChanged: (Bool) -> Void
  let onBeginDeferredResult: () -> Int
  let onClose: () -> Void
  let onOpenResult: (Peer, Destination) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appDatabase) private var database
  @EnvironmentObject private var dataManager: DataManager

  @State private var searchModel: InlineSearchViewModel?
  @State private var globalUserOpenGeneration = 0
  @FocusState private var isSearchFocused: Bool

  init(
    query: Binding<String>,
    focusRequested: Binding<Bool>,
    interactionRevision: Binding<Int>,
    isActivePresentation: Bool,
    activeSpaceId: Int64?,
    onFocusChanged: @escaping (Bool) -> Void,
    onBeginDeferredResult: @escaping () -> Int,
    onClose: @escaping () -> Void,
    onOpenResult: @escaping (Peer, Destination) -> Void
  ) {
    _query = query
    _focusRequested = focusRequested
    _interactionRevision = interactionRevision
    self.isActivePresentation = isActivePresentation
    self.activeSpaceId = activeSpaceId
    self.onFocusChanged = onFocusChanged
    self.onBeginDeferredResult = onBeginDeferredResult
    self.onClose = onClose
    self.onOpenResult = onOpenResult
  }

  var body: some View {
    ZStack {
      if let searchModel {
        InlineSearchResultsList(
          model: searchModel,
          openChat: openSearchChat,
          openMessage: openSearchMessage,
          openGlobalUser: openSearchGlobalUser,
          addToInbox: addSearchResultToInbox
        )
        .safeAreaInset(edge: .top, spacing: 0) {
          if let errorText = searchModel.errorText, searchModel.hasResults {
            searchErrorBanner(errorText)
          }
        }
      } else {
        ProgressView()
      }

      ExperimentalSearchStatusOverlay(
        state: overlayState,
        onRetry: retrySearch,
        onDismissKeyboard: dismissSearchFocus
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scrollDismissesKeyboard(.interactively)
    .modifier(ExperimentalSearchTopBar(
      input: ExperimentalSearchInput(
        text: $query,
        isFocused: $isSearchFocused,
        isActivePresentation: isActivePresentation,
        reduceMotion: reduceMotion,
        onFocusIntent: activateSearch,
        onClose: closeActiveSearch
      )
    ))
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .onAppear {
      ensureSearchModel()
      updateSearch(for: query)
    }
    .onChange(of: focusRequested) { _, shouldFocus in
      if isSearchFocused != shouldFocus {
        isSearchFocused = shouldFocus
      } else if !shouldFocus {
        // A fast tab action can cancel the focus intent before the field becomes
        // first responder. Acknowledge that settled no-keyboard state explicitly.
        onFocusChanged(false)
      }
    }
    .onChange(of: isSearchFocused) { _, isFocused in
      withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
        if focusRequested != isFocused {
          focusRequested = isFocused
        }
        onFocusChanged(isFocused)
      }
    }
    .onChange(of: query) { _, newValue in
      updateSearch(for: newValue)
    }
    .onChange(of: activeSpaceId) { _, _ in
      updateSearch(for: query)
    }
    .onDisappear {
      // A global-user selection can already have persisted optimistic local state.
      // Let that mutation settle, but invalidate its navigation and error UI.
      globalUserOpenGeneration &+= 1
      isSearchFocused = false
      focusRequested = false
      onFocusChanged(false)
    }
  }

  private var hasResults: Bool {
    searchModel?.hasResults ?? false
  }

  private var isSearching: Bool {
    searchModel?.isSearching ?? false
  }

  private var overlayState: ExperimentalSearchOverlayState {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedQuery.isEmpty {
      return .empty
    } else if isSearching && !hasResults {
      return .searching
    } else if let errorText = searchModel?.errorText, !hasResults {
      return .error(errorText)
    } else if !hasResults {
      return .noResults(trimmedQuery)
    }
    return .hidden
  }

  private func searchErrorBanner(_ errorText: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)

      Text(errorText)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      Spacer(minLength: 4)

      Button("Retry", action: retrySearch)
        .font(.footnote.weight(.semibold))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func retrySearch() {
    searchModel?.search(query, scope: searchScope)
  }

  private func dismissSearchFocus() {
    isSearchFocused = false
    focusRequested = false
  }

  private func updateSearch(for query: String) {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedQuery.isEmpty else {
      searchModel?.clear()
      return
    }

    let model = ensureSearchModel()
    if model.query == trimmedQuery {
      model.updateScope(searchScope)
    } else {
      model.search(trimmedQuery, scope: searchScope)
    }
  }

  @discardableResult
  private func ensureSearchModel() -> InlineSearchViewModel {
    if let searchModel {
      return searchModel
    }

    let model = InlineSearchViewModel(
      db: database,
      scope: searchScope,
      limits: InlineSearchLimits(
        chatLimit: 24,
        messageBatchSize: 20,
        globalUserLimit: 20,
        globalDebounceNanoseconds: 220_000_000
      )
    )
    searchModel = model
    return model
  }

  private var searchScope: InlineSearchScope {
    InlineSearchScope(
      spaceId: activeSpaceId,
      includeArchived: false,
      includeSpaceChatsInHome: true,
      includeGlobalUsers: true,
      messageSort: .relevance
    )
  }

  private func openSearchChat(_ result: InlineSearchChatResult) {
    globalUserOpenGeneration &+= 1
    openSearchDestination(result.peer)
  }

  private func openSearchMessage(_ result: LocalMessageSearchResult) {
    globalUserOpenGeneration &+= 1
    openSearchDestination(
      result.peer,
      destination: .chatMessage(peer: result.peer, messageID: result.messageId)
    )
  }

  private func openSearchGlobalUser(_ result: InlineSearchGlobalUserResult) {
    let user = result.user
    globalUserOpenGeneration &+= 1
    let generation = globalUserOpenGeneration
    let selectionRevision = onBeginDeferredResult()
    dismissSearchFocus()
    Task {
      do {
        try await dataManager.createPrivateChatWithOptimistic(user: user)
        guard generation == globalUserOpenGeneration,
              selectionRevision == interactionRevision
        else { return }
        openSearchDestination(.user(id: user.id))
      } catch {
        guard generation == globalUserOpenGeneration,
              selectionRevision == interactionRevision
        else { return }
        Log.shared.error("Failed to open private chat from experimental search", error: error)
        showGlobalUserOpenError()
      }
    }
  }

  private func openSearchDestination(_ peer: Peer, destination: Destination? = nil) {
    dismissSearchFocus()
    onOpenResult(peer, destination ?? .chat(peer: peer))
  }

  private func addSearchResultToInbox(_ peer: Peer) {
    Task(priority: .userInitiated) {
      do {
        let didPerform = try await InboxMembershipService.shared.open(peer: peer)
        guard didPerform else { return }
        ToastManager.shared.showToast(
          "Added to Inbox",
          type: .success,
          systemImage: "tray.full.fill"
        )
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to add Search result to Inbox", error: error)
        ToastManager.shared.showToast(
          "Could not add to Inbox",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func showGlobalUserOpenError() {
    ToastManager.shared.showToast(
      "Couldn’t Start Conversation",
      description: "Try again.",
      type: .error,
      systemImage: "exclamationmark.triangle.fill"
    )
  }

  private func activateSearch() {
    guard !focusRequested else { return }
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
      focusRequested = true
    }
  }

  private func closeActiveSearch() {
    globalUserOpenGeneration &+= 1
    onClose()
  }
}

private enum ExperimentalSearchOverlayState: Equatable {
  case empty
  case searching
  case error(String)
  case noResults(String)
  case hidden
}

private struct ExperimentalSearchStatusOverlay: View {
  let state: ExperimentalSearchOverlayState
  let onRetry: () -> Void
  let onDismissKeyboard: () -> Void

  var body: some View {
    ZStack {
      switch state {
      case .empty:
        ExperimentalSearchEmptyPlaceholder()

      case .searching:
        ProgressView()
          .controlSize(.large)

      case let .error(errorText):
        ContentUnavailableView {
          Label("Search unavailable", systemImage: "exclamationmark.magnifyingglass")
        } description: {
          Text(errorText)
        } actions: {
          Button("Try Again", action: onRetry)
            .buttonStyle(.borderedProminent)
        }

      case let .noResults(query):
        ContentUnavailableView.search(text: query)

      case .hidden:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(.rect)
    .simultaneousGesture(TapGesture().onEnded(onDismissKeyboard))
    .allowsHitTesting(state != .hidden)
  }
}

private struct ExperimentalSearchEmptyPlaceholder: View {
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 34, weight: .regular))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

      Text("Search messages and chats, or find Inline users by @username to start a conversation.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
    }
    .padding(.horizontal, Theme.Layout.screenEdgeOpticalInset)
    .accessibilityElement(children: .combine)
  }
}

private struct ExperimentalSearchTopBar<Input: View>: ViewModifier {
  let input: Input

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.safeAreaBar(edge: .top, spacing: 0) {
        input
      }
    } else {
      content.safeAreaInset(edge: .top, spacing: 0) {
        input
          .background(.bar)
      }
    }
  }
}

private struct ExperimentalSearchInput: View {
  @Binding var text: String
  @FocusState.Binding var isFocused: Bool
  let isActivePresentation: Bool
  let reduceMotion: Bool
  let onFocusIntent: () -> Void
  let onClose: () -> Void

  @Namespace private var glassNamespace

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 0) {
        controls
      }
    } else {
      controls
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      searchField
        .modifier(ExperimentalSearchFieldSurface(
          isActive: isActivePresentation,
          namespace: glassNamespace
        ))

      if isActivePresentation {
        closeButton
          .modifier(ExperimentalSearchCloseSurface(namespace: glassNamespace))
          .transition(closeControlTransition)
      }
    }
    .padding(.horizontal, horizontalInset)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(searchControlAnimation, value: isActivePresentation)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)

        TextField("Search chats, messages, and people", text: $text)
          .focused($isFocused)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.search)
          .onSubmit {
            isFocused = false
          }
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(.rect)
      .simultaneousGesture(TapGesture().onEnded(onFocusIntent))

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 44)
    .frame(maxWidth: .infinity)
    .contentShape(.capsule)
  }

  private var closeButton: some View {
    Button {
      isFocused = false
      onClose()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 40, height: 40)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close Search")
  }

  private var searchControlAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.2)
  }

  private var closeControlTransition: AnyTransition {
    reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity)
  }

  private var horizontalInset: CGFloat {
    max(0, Theme.Layout.screenEdgeOpticalInset - 8)
  }
}

private struct ExperimentalSearchFieldSurface: ViewModifier {
  let isActive: Bool
  let namespace: Namespace.ID

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .background(Color(.secondarySystemFill).opacity(isActive ? 0 : 1), in: Capsule())
        .glassEffect(isActive ? .regular.interactive() : .identity, in: .capsule)
        .glassEffectID("search-field", in: namespace)
    } else {
      content
        .background {
          ZStack {
            Capsule()
              .fill(Color(.secondarySystemFill))
              .opacity(isActive ? 0 : 1)

            Capsule()
              .fill(.thinMaterial)
              .opacity(isActive ? 1 : 0)
          }
        }
    }
  }
}

private struct ExperimentalSearchCloseSurface: ViewModifier {
  let namespace: Namespace.ID

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("search-close", in: namespace)
        .glassEffectTransition(.materialize)
    } else {
      content
        .background {
          Circle()
            .fill(.thinMaterial)
        }
    }
  }
}
