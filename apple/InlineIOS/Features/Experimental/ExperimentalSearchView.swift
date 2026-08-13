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
    VStack(spacing: 0) {
      ExperimentalSearchInput(
        text: $query,
        isFocused: $isSearchFocused,
        isActivePresentation: isActivePresentation,
        reduceMotion: reduceMotion,
        onFocusIntent: activateSearch,
        onClose: closeActiveSearch
      )

      ZStack {
        if let searchModel {
          InlineSearchResultsList(
            model: searchModel,
            openChat: openSearchChat,
            openMessage: openSearchMessage,
            openGlobalUser: openSearchGlobalUser
          )
          .safeAreaInset(edge: .top, spacing: 0) {
            if let errorText = searchModel.errorText, searchModel.hasResults {
              searchErrorBanner(errorText)
            }
          }
        } else {
          ProgressView()
        }

        overlayContent
          .contentShape(.rect)
          .onTapGesture {
            focusRequested = false
          }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .scrollDismissesKeyboard(.interactively)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
      searchModel?.clear()
    }
  }

  private var hasResults: Bool {
    searchModel?.hasResults ?? false
  }

  private var isSearching: Bool {
    searchModel?.isSearching ?? false
  }

  @ViewBuilder
  private var overlayContent: some View {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedQuery.isEmpty {
      ContentUnavailableView(
        "Search for chats and people",
        systemImage: "magnifyingglass",
        description: Text("Type to find existing chats or search for people to start new conversations")
      )
    } else if isSearching && !hasResults {
      ProgressView()
        .controlSize(.large)
    } else if let errorText = searchModel?.errorText, !hasResults {
      ContentUnavailableView {
        Label("Search unavailable", systemImage: "exclamationmark.magnifyingglass")
      } description: {
        Text(errorText)
      } actions: {
        Button("Try Again", action: retrySearch)
          .buttonStyle(.borderedProminent)
      }
    } else if !hasResults {
      ContentUnavailableView.search(text: trimmedQuery)
    }
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

  private func updateSearch(for query: String) {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedQuery.isEmpty else {
      searchModel?.clear()
      return
    }

    ensureSearchModel().search(trimmedQuery, scope: searchScope)
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
    openInInbox(result.peer)
  }

  private func openSearchMessage(_ result: LocalMessageSearchResult) {
    globalUserOpenGeneration &+= 1
    openInInbox(
      result.peer,
      destination: .chatMessage(peer: result.peer, messageID: result.messageId)
    )
  }

  private func openSearchGlobalUser(_ result: InlineSearchGlobalUserResult) {
    let user = result.user
    globalUserOpenGeneration &+= 1
    let generation = globalUserOpenGeneration
    let selectionRevision = onBeginDeferredResult()
    focusRequested = false
    Task {
      do {
        try await dataManager.createPrivateChatWithOptimistic(user: user)
        guard generation == globalUserOpenGeneration,
              selectionRevision == interactionRevision
        else { return }
        openInInbox(.user(id: user.id))
      } catch {
        guard generation == globalUserOpenGeneration,
              selectionRevision == interactionRevision
        else { return }
        Log.shared.error("Failed to open private chat from experimental search", error: error)
        showOpenError()
      }
    }
  }

  private func openInInbox(_ peer: Peer, destination: Destination? = nil) {
    onOpenResult(peer, destination ?? .chat(peer: peer))

    Task {
      do {
        _ = try await InboxMembershipService.shared.open(peer: peer)
      } catch {
        Log.shared.error("Failed to open search result in Inbox", error: error)
        showOpenError()
      }
    }
  }

  private func showOpenError() {
    ToastManager.shared.showToast(
      "Could not update Inbox",
      description: "The chat opened, but Inbox could not be updated. Try again.",
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

private struct ExperimentalSearchInput: View {
  @Binding var text: String
  @FocusState.Binding var isFocused: Bool
  let isActivePresentation: Bool
  let reduceMotion: Bool
  let onFocusIntent: () -> Void
  let onClose: () -> Void

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 12) {
        controls
      }
    } else {
      controls
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      searchField
        .modifier(ExperimentalSearchFieldSurface(isActive: isActivePresentation))

      if isActivePresentation {
        closeButton
          .modifier(ExperimentalSearchCloseSurface())
          .transition(closeTransition)
      }
    }
    .padding(.horizontal, 16)
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

  private var closeTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .opacity.combined(with: .scale(scale: 0.9))
  }
}

private struct ExperimentalSearchFieldSurface: ViewModifier {
  let isActive: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .background(Color(.secondarySystemFill), in: Capsule())
        .glassEffect(isActive ? .regular.interactive() : .identity, in: .capsule)
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
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      content
        .background(.thinMaterial, in: Circle())
    }
  }
}
