import InlineKit
import InlineUI
import Intents
import SwiftUI
import UIKit

struct ShareView: View {
  @EnvironmentObject private var state: ShareState
  @Environment(\.extensionContext) private var extensionContext
  @Environment(\.locale) private var locale

  @State private var searchText = ""
  @State private var isSearching = false
  @State private var selectedChatIDs = Set<Int64>()
  @State private var caption = ""
  @State private var didApplyPreselectedDestination = false
  @State private var allChats: [SharedChat] = []
  @State private var filteredChats: [SharedChat] = []

  private var users: [SharedUser] {
    state.sharedData?.shareExtensionData.users ?? []
  }

  private var selectedChats: [SharedChat] {
    allChats.filter { selectedChatIDs.contains($0.id) }
  }

  private var canSend: Bool {
    !selectedChats.isEmpty && state.sharedContent != nil && !state.isSending && !state.isLoadingContent
  }

  private var navigationSubtitle: String {
    if selectedChats.count == 1 {
      return selectedChats[0].displayTitle(users: users)
    }
    if selectedChats.count > 1 {
      return "\(selectedChats.count) selected"
    }
    guard let content = state.sharedContent else { return "Share to Inline" }
    return content.summaryTitle
  }

  var body: some View {
    NavigationStack {
      contentView
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(action: completeRequest) {
              Label("Cancel", systemImage: "xmark")
                .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Cancel")
            .disabled(state.isSending)
          }

          ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
              Text("Send to")
                .font(.headline)
                .foregroundStyle(.primary)
              Text(navigationSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: 220)
          }

          if state.sharedContent != nil, !state.isSending, !state.isSent, !isSearching {
            ToolbarItem(placement: .primaryAction) {
              Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                  isSearching = true
                }
              } label: {
                Label("Search", systemImage: "magnifyingglass")
                  .labelStyle(.iconOnly)
              }
              .accessibilityLabel("Search chats")
            }
          }
        }
    }
    .onAppear {
      state.loadSharedData()
      refreshChats()
      applyPreselectedDestinationIfNeeded()
    }
    .onChange(of: state.sharedData?.lastUpdate) {
      refreshChats()
      applyPreselectedDestinationIfNeeded()
    }
    .onChange(of: searchText) {
      refreshFilteredChats()
    }
    .alert(
      state.errorState?.title ?? "Error",
      isPresented: Binding(
        get: { state.errorState != nil },
        set: { isPresented in
          guard !isPresented else { return }
          Task { @MainActor in
            state.errorState = nil
          }
        }
      )
    ) {
      if state.errorState?.retryable == true {
        Button("Try Again", action: retrySend)
      }
      Button("OK", role: .cancel) {
        state.errorState = nil
      }
    } message: {
      VStack(alignment: .leading, spacing: 4) {
        if let message = state.errorState?.message {
          Text(message)
        }
        if let suggestion = state.errorState?.suggestion {
          Text(suggestion)
        }
      }
    }
  }

  @ViewBuilder
  private var contentView: some View {
    if state.isSending || state.isSent {
      ShareDeliveryStatusView(
        progress: state.sendProgress,
        isComplete: state.isSent
      )
    } else if state.isLoadingContent {
      ShareLoadingView(progress: state.sendProgress)
    } else if state.sharedContent == nil {
      ShareNoContentView()
    } else {
      destinationPicker
    }
  }

  private var destinationPicker: some View {
    ShareDestinationPicker(
      chats: filteredChats,
      users: users,
      warnings: state.contentWarnings,
      searchText: $searchText,
      isSearching: $isSearching,
      selectedChatIDs: $selectedChatIDs,
      caption: $caption,
      canSend: canSend,
      onSend: send
    )
  }

  private func send() {
    let chats = selectedChats
    guard !chats.isEmpty else { return }
    isSearching = false
    state.sendMessage(caption: caption, selectedChats: chats, completion: completeRequest)
  }

  private func retrySend() {
    state.errorState = nil
    send()
  }

  private func completeRequest() {
    let extensionContext = extensionContext
    Task { @MainActor in
      await state.finishSession()
      extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
  }

  private func applyPreselectedDestinationIfNeeded() {
    guard !didApplyPreselectedDestination else { return }
    guard selectedChatIDs.isEmpty else {
      didApplyPreselectedDestination = true
      return
    }
    guard let intent = extensionContext?.intent as? INSendMessageIntent,
          let conversationIdentifier = intent.conversationIdentifier,
          let chat = allChats.first(where: { $0.matchesIntentConversationIdentifier(conversationIdentifier) })
    else {
      return
    }
    selectedChatIDs = [chat.id]
    didApplyPreselectedDestination = true
  }

  private func sortChats(_ chats: [SharedChat]) -> [SharedChat] {
    chats.sorted { lhs, rhs in
      let lhsArchived = lhs.archived ?? false
      let rhsArchived = rhs.archived ?? false
      if lhsArchived != rhsArchived { return !lhsArchived && rhsArchived }

      let lhsPinned = lhs.pinned ?? false
      let rhsPinned = rhs.pinned ?? false
      if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
      if lhsPinned, rhsPinned { return lhs.id > rhs.id }

      let lhsDate = lhs.lastMessageDate ?? .distantPast
      let rhsDate = rhs.lastMessageDate ?? .distantPast
      if lhsDate == rhsDate {
        return lhs.id > rhs.id
      }
      return lhsDate > rhsDate
    }
  }

  private func normalizeSearchText(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
      .lowercased()
  }

  private func refreshChats() {
    let chats = sortChats(state.sharedData?.shareExtensionData.chats ?? [])
    allChats = chats
    selectedChatIDs.formIntersection(chats.lazy.map(\.id))
    filteredChats = filterChats(chats)
  }

  private func refreshFilteredChats() {
    filteredChats = filterChats(allChats)
  }

  private func filterChats(_ chats: [SharedChat]) -> [SharedChat] {
    let normalizedQuery = normalizeSearchText(searchText)
    guard !normalizedQuery.isEmpty else { return chats }
    return chats.filter { chat in
      chat.searchTextForMatching(users: users, locale: locale).contains(normalizedQuery)
    }
  }
}

private struct ShareDestinationPicker: View {
  let chats: [SharedChat]
  let users: [SharedUser]
  let warnings: [String]
  @Binding var searchText: String
  @Binding var isSearching: Bool
  @Binding var selectedChatIDs: Set<Int64>
  @Binding var caption: String
  let canSend: Bool
  let onSend: () -> Void

  var body: some View {
    ShareDestinationChrome(
      chats: chats,
      users: users,
      warnings: warnings,
      searchText: $searchText,
      isSearching: $isSearching,
      selectedChatIDs: $selectedChatIDs,
      caption: $caption,
      canSend: canSend,
      onSend: onSend
    )
  }
}

private struct ShareDestinationChrome: View {
  let chats: [SharedChat]
  let users: [SharedUser]
  let warnings: [String]
  @Binding var searchText: String
  @Binding var isSearching: Bool
  @Binding var selectedChatIDs: Set<Int64>
  @Binding var caption: String
  let canSend: Bool
  let onSend: () -> Void

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      destinationList
        .safeAreaBar(edge: .bottom, spacing: 0) {
          if isSearching {
            searchBar
              .transition(.opacity)
          } else if !selectedChatIDs.isEmpty {
            composer
              .transition(.opacity)
          }
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
    } else {
      destinationList
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if isSearching {
            searchBar
              .background(.bar)
              .overlay(alignment: .top) {
                Divider()
              }
              .transition(.opacity)
          } else if !selectedChatIDs.isEmpty {
            composer
              .background(.bar)
              .overlay(alignment: .top) {
                Divider()
              }
              .transition(.opacity)
          }
        }
    }
  }

  private var destinationList: some View {
    ShareDestinationList(
      chats: chats,
      users: users,
      searchText: searchText,
      selectedChatIDs: $selectedChatIDs
    )
  }

  private var composer: some View {
    ShareComposerBar(
      warnings: warnings,
      canSend: canSend,
      caption: $caption,
      onSend: onSend
    )
  }

  private var searchBar: some View {
    ShareSearchBar(text: $searchText) {
      searchText = ""
      withAnimation(.easeInOut(duration: 0.18)) {
        isSearching = false
      }
    }
  }
}

private struct ShareDestinationList: View {
  let chats: [SharedChat]
  let users: [SharedUser]
  let searchText: String
  @Binding var selectedChatIDs: Set<Int64>

  var body: some View {
    List {
      if chats.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, minHeight: 240)
          .listRowSeparator(.hidden)
      } else {
        ForEach(chats, id: \.id) { chat in
          Button {
            toggleSelection(chat)
          } label: {
            ShareDestinationRow(
              chat: chat,
              user: user(for: chat),
              isSelected: selectedChatIDs.contains(chat.id)
            )
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        }
      }
    }
    .listStyle(.plain)
    .scrollDismissesKeyboard(.interactively)
  }

  private func toggleSelection(_ chat: SharedChat) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
      if selectedChatIDs.contains(chat.id) {
        selectedChatIDs.remove(chat.id)
      } else {
        selectedChatIDs.insert(chat.id)
      }
    }
  }

  private func user(for chat: SharedChat) -> SharedUser? {
    guard let peerUserId = chat.peerUserId else { return nil }
    return users.first(where: { $0.id == peerUserId })
  }
}

private struct ShareDestinationRow: View, Equatable {
  let chat: SharedChat
  let user: SharedUser?
  let isSelected: Bool

  private static let avatarSize: CGFloat = 34
  private static let minimumRowHeight: CGFloat = 46

  nonisolated static func == (lhs: ShareDestinationRow, rhs: ShareDestinationRow) -> Bool {
    lhs.chat.id == rhs.chat.id
      && lhs.chat.title == rhs.chat.title
      && lhs.chat.pinned == rhs.chat.pinned
      && lhs.chat.emoji == rhs.chat.emoji
      && lhs.chat.isReplyThread == rhs.chat.isReplyThread
      && lhs.user == rhs.user
      && lhs.isSelected == rhs.isSelected
  }

  var body: some View {
    HStack(spacing: 10) {
      ShareAvatarView(chat: chat, user: user, size: Self.avatarSize)

      HStack(spacing: 6) {
        Text(chat.displayTitle(user: user))
          .font(.body)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if chat.pinned == true {
          Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pinned")
        }
      }

      ShareSelectionIndicator(isSelected: isSelected)
        .accessibilityHidden(true)
    }
    .frame(minHeight: Self.minimumRowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct ShareSelectionIndicator: View, Equatable {
  let isSelected: Bool

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(Color.secondary.opacity(isSelected ? 0 : 0.36), lineWidth: 1.6)

      Circle()
        .fill(Color.accentColor)
        .scaleEffect(isSelected ? 1 : 0.72)
        .opacity(isSelected ? 1 : 0)

      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .scaleEffect(isSelected ? 1 : 0.55)
        .opacity(isSelected ? 1 : 0)
    }
    .frame(width: 22, height: 22)
    .animation(.snappy(duration: 0.14, extraBounce: 0), value: isSelected)
  }
}

private struct ShareAvatarView: View, Equatable {
  let chat: SharedChat
  let user: SharedUser?
  let size: CGFloat

  nonisolated static func == (lhs: ShareAvatarView, rhs: ShareAvatarView) -> Bool {
    lhs.chat.id == rhs.chat.id
      && lhs.chat.title == rhs.chat.title
      && lhs.chat.emoji == rhs.chat.emoji
      && lhs.chat.isReplyThread == rhs.chat.isReplyThread
      && lhs.user == rhs.user
      && lhs.size == rhs.size
  }

  var body: some View {
    Group {
      if let user {
        UserAvatar(
          user: user.inlineUser,
          size: size,
          cacheRemoteAvatar: false,
          localAvatarURL: user.sharedAvatarURL
        )
      } else {
        ThreadIconView(
          ThreadIconDescriptor(
            emoji: chat.emoji,
            title: chat.displayTitle(user: nil),
            isReplyThread: chat.isReplyThread ?? (chat.peerThreadId != nil),
            accessibilityLabel: chat.displayTitle(user: nil)
          ),
          size: .compact(size),
          shape: .circle
        )
      }
    }
    .frame(width: size, height: size)
    .fixedSize()
  }
}

private struct ShareComposerBar: View {
  let warnings: [String]
  let canSend: Bool
  @Binding var caption: String
  let onSend: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !warnings.isEmpty {
        Label(warnings.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      ShareCommentField(caption: $caption)
      ShareSendButton(
        isEnabled: canSend,
        action: onSend
      )
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.18, extraBounce: 0), value: warnings)
  }
}

private struct ShareSearchBar: View {
  @Binding var text: String
  let onCancel: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 12) {
      searchField

      Button("Cancel") {
        isFocused = false
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(160))
          onCancel()
        }
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .task {
      do {
        try await Task.sleep(for: .milliseconds(200))
      } catch {
        return
      }
      isFocused = true
    }
  }

  @ViewBuilder
  private var searchField: some View {
    if #available(iOS 26.0, *) {
      fieldContent
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    } else {
      fieldContent
        .background(Color(uiColor: .secondarySystemFill), in: .rect(cornerRadius: 24))
    }
  }

  private var fieldContent: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .font(.body.weight(.medium))
        .foregroundStyle(.secondary)

      TextField("Search chats", text: $text)
        .textFieldStyle(.plain)
        .font(.body)
        .submitLabel(.search)
        .focused($isFocused)

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(minHeight: 48)
  }
}

private struct ShareCommentField: View {
  @Binding var caption: String
  @FocusState private var isFocused: Bool

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      field
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    } else {
      field
        .background {
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(uiColor: .secondarySystemFill))
            .overlay {
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                  isFocused ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12),
                  lineWidth: 1
                )
            }
        }
    }
  }

  private var field: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Write a message", text: $caption, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.body)
        .lineLimit(1 ... 4)
        .submitLabel(.done)
        .focused($isFocused)
        .onSubmit {
          isFocused = false
        }
        .textInputAutocapitalization(.sentences)
        .autocorrectionDisabled(false)
        .accessibilityLabel("Write a message")

      if !caption.isEmpty {
        Button {
          withAnimation(.snappy(duration: 0.14, extraBounce: 0)) {
            caption = ""
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 26, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear comment")
        .transition(.scale(scale: 0.8).combined(with: .opacity))
      }
    }
    .padding(.leading, 13)
    .padding(.trailing, caption.isEmpty ? 14 : 8)
    .padding(.vertical, 9)
    .frame(minHeight: 48)
    .animation(.snappy(duration: 0.16, extraBounce: 0), value: caption.isEmpty)
  }
}

private struct ShareSendButton: View {
  let isEnabled: Bool
  let action: () -> Void

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      button
        .buttonStyle(.glassProminent)
    } else {
      button
        .buttonStyle(.borderedProminent)
        .clipShape(.capsule)
    }
  }

  private var button: some View {
    Button(action: action) {
      Text("Send")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .font(.body.weight(.semibold))
    .disabled(!isEnabled)
  }
}

private struct ShareDeliveryStatusView: View {
  let progress: ShareState.ShareProgressState
  let isComplete: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var title: String {
    if isComplete { return "Sent" }
    return progress.title.isEmpty ? "Sending" : progress.title
  }

  var body: some View {
    VStack(spacing: 16) {
      ShareProgressRing(
        progress: progress.fractionCompleted,
        isComplete: isComplete
      )
      .frame(width: 64, height: 64)

      VStack(spacing: 5) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .contentTransition(.opacity)

        Text(progress.detailText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .multilineTextAlignment(.center)
          .opacity(progress.hasDetail ? 1 : 0)
          .contentTransition(.opacity)
      }
      .frame(height: 38, alignment: .top)
    }
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: progress)
    .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: isComplete)
  }
}

private struct ShareLoadingView: View {
  let progress: ShareState.ShareProgressState

  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
      Text(progress.title.isEmpty ? "Preparing" : progress.title)
        .font(.headline)
        .foregroundStyle(.primary)
      if let detail = progress.detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ShareProgressRing: View {
  let progress: Double?
  let isComplete: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedProgress: Double = 0
  @State private var showCheckmark = false

  private var clampedProgress: Double {
    min(max(progress ?? 0, 0), 1)
  }

  private var ringColor: Color {
    isComplete ? .green : .accentColor
  }

  private var isIndeterminate: Bool {
    progress == nil && !isComplete
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.18), lineWidth: 4)

      if isIndeterminate {
        if reduceMotion {
          progressArc(trim: 0.22)
            .rotationEffect(.degrees(-90))
        } else {
          ShareIndeterminateProgressArc(color: ringColor)
        }
      } else {
        progressArc(trim: isComplete ? 1 : max(displayedProgress, 0.04))
          .rotationEffect(.degrees(-90))
          .transition(.opacity)
      }

      Image(systemName: "checkmark")
        .font(.system(size: 23, weight: .bold))
        .foregroundStyle(.green)
        .scaleEffect(showCheckmark ? 1 : 0.55)
        .opacity(showCheckmark ? 1 : 0)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isIndeterminate)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isComplete)
    .onAppear {
      if reduceMotion {
        displayedProgress = clampedProgress
        showCheckmark = isComplete
        return
      }

      if isComplete {
        displayedProgress = 0.82
        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
          displayedProgress = 1
        }
        withAnimation(.spring(duration: 0.34, bounce: 0.28).delay(0.12)) {
          showCheckmark = true
        }
      } else {
        withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
          displayedProgress = clampedProgress
        }
      }
    }
    .onChange(of: progress) { _, newValue in
      guard let newValue else { return }
      let nextProgress = max(displayedProgress, min(max(newValue, 0), 1))
      if reduceMotion {
        displayedProgress = nextProgress
      } else {
        withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
          displayedProgress = nextProgress
        }
      }
    }
    .onChange(of: isComplete) { _, completed in
      if reduceMotion {
        displayedProgress = completed ? 1 : displayedProgress
        showCheckmark = completed
      } else if completed {
        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
          displayedProgress = 1
        }
        withAnimation(.spring(duration: 0.34, bounce: 0.28).delay(0.12)) {
          showCheckmark = true
        }
      }
    }
  }

  private func progressArc(trim: Double) -> some View {
    Circle()
      .trim(from: 0, to: trim)
      .stroke(
        ringColor,
        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
      )
  }
}

private struct ShareIndeterminateProgressArc: View {
  let color: Color

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 60)) { context in
      let duration = 0.85
      let elapsed = context.date.timeIntervalSinceReferenceDate
      let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration

      Circle()
        .trim(from: 0, to: 0.22)
        .stroke(
          color,
          style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        )
        .rotationEffect(.degrees((phase * 360) - 90))
    }
  }
}

private extension ShareState.ShareProgressState {
  var hasDetail: Bool {
    guard let detail else { return false }
    return !detail.isEmpty
  }

  var detailText: String {
    guard hasDetail, let detail else { return " " }
    return detail
  }
}

private struct ShareNoContentView: View {
  var body: some View {
    ContentUnavailableView(
      "Nothing to Share",
      systemImage: "tray",
      description: Text("Choose text, media, a link, or a file and try again.")
    )
  }
}

private extension SharedChat {
  func displayTitle(user: SharedUser?) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty { return trimmedTitle }
    if let user { return user.displayTitle }
    return "Chat"
  }

  func displayTitle(users: [SharedUser]) -> String {
    let user = peerUserId.flatMap { id in users.first(where: { $0.id == id }) }
    return displayTitle(user: user)
  }

  func searchTextForMatching(users: [SharedUser], locale: Locale) -> String {
    if let searchText, !searchText.isEmpty {
      return searchText
    }

    return [
      displayTitle(users: users),
      parentTitle,
      preview,
      spaceName,
      peerUserId.flatMap { id in users.first(where: { $0.id == id })?.displayTitle },
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    .lowercased()
  }

  func matchesIntentConversationIdentifier(_ identifier: String) -> Bool {
    if let peerUserId, identifier == "inline:user:\(peerUserId)" { return true }
    if let peerThreadId, identifier == "inline:thread:\(peerThreadId)" { return true }
    return identifier == "inline:chat:\(id)"
  }
}

private extension SharedUser {
  var displayTitle: String {
    if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !displayName.isEmpty {
      return displayName
    }

    let fullName = [firstName, lastName]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    if !fullName.isEmpty { return fullName }
    if let username = username?.trimmingCharacters(in: .whitespacesAndNewlines),
       !username.isEmpty {
      return username
    }
    if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
       !email.isEmpty {
      return email
    }
    return "User"
  }

  var inlineUser: User {
    var user = User(
      id: id,
      email: email,
      firstName: firstName.isEmpty ? nil : firstName,
      lastName: lastName.isEmpty ? nil : lastName,
      username: username
    )
    user.profileCdnUrl = profileCdnUrl
    user.profileLocalPath = profileLocalPath
    user.profileFileUniqueId = profileFileUniqueId
    return user
  }
}

extension EnvironmentValues {
  @Entry var extensionContext: NSExtensionContext?
}
