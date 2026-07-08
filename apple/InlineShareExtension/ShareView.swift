import InlineKit
import InlineUI
import Intents
import SwiftUI
import UIKit

struct ShareView: View {
  @EnvironmentObject private var state: ShareState
  @Environment(\.extensionContext) private var extensionContext

  @State private var searchText = ""
  @State private var selectedChatIDs = Set<Int64>()
  @State private var caption = ""
  @State private var didApplyPreselectedDestination = false

  private var users: [SharedUser] {
    state.sharedData?.shareExtensionData.users ?? []
  }

  private var allChats: [SharedChat] {
    sortChats(state.sharedData?.shareExtensionData.chats ?? [])
  }

  private var filteredChats: [SharedChat] {
    guard !searchText.isEmpty else { return allChats }
    let normalizedQuery = normalizeSearchText(searchText)
    return allChats.filter { chat in
      chat.searchTextForMatching(users: users).contains(normalizedQuery)
    }
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
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Cancel")
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
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

          ToolbarItem(placement: .confirmationAction) {
            Button(action: send) {
              Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
            }
            .accessibilityLabel("Send")
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .opacity(state.sharedContent == nil || state.isSent ? 0 : 1)
          }
        }
    }
    .onAppear {
      state.loadSharedData()
      applyPreselectedDestinationIfNeeded()
    }
    .onChange(of: state.sharedData?.lastUpdate) {
      applyPreselectedDestinationIfNeeded()
    }
    .alert(
      state.errorState?.title ?? "Error",
      isPresented: Binding(
        get: { state.errorState != nil },
        set: { if !$0 { state.errorState = nil } }
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
    if state.isSent {
      ShareSuccessView()
    } else if state.isSending {
      ShareSendingView(progress: state.sendProgress)
    } else if state.isLoadingContent {
      ShareLoadingView(progress: state.sendProgress)
    } else if state.sharedContent == nil {
      ShareNoContentView()
    } else {
      destinationPicker
    }
  }

  private var destinationPicker: some View {
    VStack(spacing: 0) {
      ShareSearchField(text: $searchText)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)

      List {
        if filteredChats.isEmpty {
          emptyState
        } else {
          ForEach(filteredChats, id: \.id) { chat in
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
    }
    .safeAreaInset(edge: .bottom) {
      if !selectedChatIDs.isEmpty {
        ShareComposerBar(
          warnings: state.contentWarnings,
          caption: $caption
        )
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView.search(text: searchText)
      .frame(maxWidth: .infinity, minHeight: 240)
      .listRowSeparator(.hidden)
  }

  private func toggleSelection(_ chat: SharedChat) {
    if selectedChatIDs.contains(chat.id) {
      selectedChatIDs.remove(chat.id)
    } else {
      selectedChatIDs.insert(chat.id)
    }
  }

  private func send() {
    let chats = selectedChats
    guard !chats.isEmpty else { return }
    state.sendMessage(caption: caption, selectedChats: chats, completion: completeRequest)
  }

  private func retrySend() {
    state.errorState = nil
    send()
  }

  private func completeRequest() {
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
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

  private func user(for chat: SharedChat) -> SharedUser? {
    guard let peerUserId = chat.peerUserId else { return nil }
    return users.first(where: { $0.id == peerUserId })
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
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }
}

private struct ShareDestinationRow: View, Equatable {
  let chat: SharedChat
  let user: SharedUser?
  let isSelected: Bool

  private static let avatarSize: CGFloat = 34
  private static let rowHeight: CGFloat = 46

  nonisolated static func == (lhs: ShareDestinationRow, rhs: ShareDestinationRow) -> Bool {
    lhs.chat.id == rhs.chat.id
      && lhs.chat.title == rhs.chat.title
      && lhs.chat.pinned == rhs.chat.pinned
      && lhs.chat.unread == rhs.chat.unread
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
          .font(.system(size: 17))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if chat.pinned == true {
          Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pinned")
        }

        if chat.unread == true {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Unread")
        }
      }

      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityHidden(true)
    }
    .frame(height: Self.rowHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        UserAvatar(user: user.inlineUser, size: size)
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

private struct ShareSearchField: View {
  @Binding var text: String

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.secondary)

      TextField("Search", text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 17))
        .submitLabel(.search)

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 15)
    .frame(height: 44)
    .background(Color(.secondarySystemFill), in: .capsule)
  }
}

private struct ShareComposerBar: View {
  let warnings: [String]
  @Binding var caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let warning = warnings.first {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
          .padding(.horizontal, 8)
      }

      TextField("Message", text: $caption, axis: .vertical)
        .lineLimit(1 ... 4)
        .font(.system(size: 17))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Message")
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 8)
  }
}

private struct ShareSendingView: View {
  let progress: ShareState.ShareProgressState

  var body: some View {
    VStack(spacing: 14) {
      ShareProgressRing(
        progress: progress.fractionCompleted ?? 0,
        isComplete: false
      )
      .frame(width: 62, height: 62)

      VStack(spacing: 4) {
        Text(progress.title.isEmpty ? "Sending" : progress.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)

        if let detail = progress.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
        }
      }
    }
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct ShareSuccessView: View {
  var body: some View {
    VStack(spacing: 14) {
      ShareProgressRing(progress: 1, isComplete: true)
        .frame(width: 62, height: 62)
      Text("Sent")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ShareProgressRing: View {
  let progress: Double
  let isComplete: Bool

  @State private var displayedProgress: Double = 0
  @State private var rotation: Double = 0

  private var clampedProgress: Double {
    min(max(progress, 0), 1)
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.18), lineWidth: 4)

      Circle()
        .trim(from: 0, to: isComplete ? 1 : max(displayedProgress, 0.08))
        .stroke(
          Color.accentColor,
          style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        )
        .rotationEffect(.degrees(-90 + (isComplete ? 0 : rotation)))

      if isComplete {
        Image(systemName: "checkmark")
          .font(.system(size: 23, weight: .bold))
          .foregroundStyle(Color.accentColor)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .onAppear {
      displayedProgress = clampedProgress
      guard !isComplete else { return }
      withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
        rotation = 360
      }
    }
    .onChange(of: progress) { _, newValue in
      withAnimation(.easeOut(duration: 0.22)) {
        displayedProgress = min(max(newValue, 0), 1)
      }
    }
    .onChange(of: isComplete) { _, completed in
      guard completed else { return }
      withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
        displayedProgress = 1
      }
    }
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

  func searchTextForMatching(users: [SharedUser]) -> String {
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
    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
