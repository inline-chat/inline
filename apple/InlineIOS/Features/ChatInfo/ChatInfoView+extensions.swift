import GRDB
import InlineKit
import InlineUI
import Logger
import MCEmojiPicker
import SwiftUI
import UIKit

extension ChatInfoView {
  func cancelParticipantSearch(clearResults: Bool = true) {
    participantSearchGeneration &+= 1
    participantSearchTask?.cancel()
    participantSearchTask = nil
    if clearResults {
      searchResults = []
    }
    isSearchingState = false
  }

  func searchUsers(query: String) {
    participantSearchTask?.cancel()
    participantSearchTask = nil
    participantSearchGeneration &+= 1
    let generation = participantSearchGeneration
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      isSearchingState = false
      return
    }

    let excludedUserIDs = participantsWithMembersViewModel.effectiveUserIds

    if currentChat?.spaceId != nil {
      searchResults = spaceFullMembersViewModel.filteredMembers
        .map(\.userInfo)
        .filter {
          // A bot can be added only by someone who can reach it.
          !excludedUserIDs.contains($0.user.id) && AgentGrantStore.shared.offers($0.user) &&
            InviteDirectory.localUserMatches($0, query: query, includeEmail: true)
        }
        .sorted { $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending }
      isSearchingState = false
      return
    }

    let shouldSearchRemotely = InviteDirectory.remoteSearchIsEligible(query: query)
    isSearchingState = shouldSearchRemotely
    searchResults = []
    participantSearchTask = Task {
      do {
        // A locally known bot is offered only to someone who can reach it;
        // the server applies the same rule to what it returns.
        let local = try await InviteDirectory.mergedUsers(
          local: InviteDirectory.localUsers(query: query, database: database),
          remote: [],
          excluding: excludedUserIDs
        ).filter { AgentGrantStore.shared.offers($0.user) }
        try Task.checkCancellation()
        guard participantSearchIsCurrent(generation, query: query) else { return }
        searchResults = local

        guard shouldSearchRemotely else {
          isSearchingState = false
          return
        }

        let remote = try await InviteDirectory.remoteUsers(
          query: query,
          realtime: Api.realtime,
          database: database
        )
        try Task.checkCancellation()
        guard participantSearchIsCurrent(generation, query: query) else { return }
        searchResults = InviteDirectory.mergedUsers(
          local: local,
          remote: remote,
          excluding: excludedUserIDs
        )
        isSearchingState = false
      } catch is CancellationError {
        return
      } catch {
        guard participantSearchIsCurrent(generation, query: query) else { return }
        Log.shared.error("Error searching users", error: error)
        isSearchingState = false
      }
    }
  }

  private func participantSearchIsCurrent(_ generation: UInt64, query: String) -> Bool {
    generation == participantSearchGeneration &&
      searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
  }

  func addParticipant(_ userInfo: UserInfo) {
    guard currentChatId != 0 else {
      Log.shared.error("No chat ID found when trying to add participant")
      return
    }
    cancelParticipantSearch(clearResults: false)
    Task {
      do {
        try await Api.realtime.send(.addChatParticipant(
          chatID: currentChatId,
          userID: userInfo.user.id
        ))
        isSearching = false
        searchText = ""
      } catch {
        Log.shared.error("Failed to add participant", error: error)
      }
    }
  }

  func addGroupParticipant(_ group: UserGroup) {
    guard currentChatId != 0 else {
      Log.shared.error("No chat ID found when trying to add group participant")
      return
    }
    cancelParticipantSearch(clearResults: false)

    Task {
      do {
        try await Api.realtime.send(.addChatParticipant(
          chatID: currentChatId,
          groupID: group.id
        ))
        isSearching = false
        searchText = ""
      } catch {
        Log.shared.error("Failed to add group participant", error: error)
      }
    }
  }

  func removeGroupParticipant(_ group: UserGroup) {
    guard currentChatId != 0 else {
      Log.shared.error("No chat ID found when trying to remove group participant")
      return
    }

    Task {
      do {
        try await Api.realtime.send(.removeChatParticipant(
          chatID: currentChatId,
          groupID: group.id
        ))
      } catch {
        Log.shared.error("Failed to remove group participant", error: error)
      }
    }
  }

  var groupSearchResults: [UserGroup] {
    let existingGroupIds = Set(participantsWithMembersViewModel.groupParticipants.map(\.id))
    let groups = userGroupsViewModel.groups.filter { !existingGroupIds.contains($0.id) }
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !query.isEmpty else { return groups }

    return groups.filter { group in
      group.name.localizedCaseInsensitiveContains(query) ||
        (group.description?.localizedCaseInsensitiveContains(query) == true)
    }
  }

  func showMessageInChat(_ message: Message) {
    if isPresentedAsSheet { dismiss() }
    // Through the router on both layouts: popping the chat and posting a scroll notice left
    // the phone on the chat list, and the message list no longer listens for it.
    router.resetTransientPresentation()
    // After the reset, so the jump carries a revision no earlier request used.
    if showMessageInPresentingChat?(chatItem.peerId, message.messageId) == true { return }
    router.openPrimaryDestination(
      .chatMessage(peer: chatItem.peerId, messageID: message.messageId)
    )
  }

  var chatInfoHeader: some View {
    VStack(spacing: 6) {
      if isDM, let userInfo = chatItem.userInfo {
        let avatarSize: CGFloat = 92
        Group {
          if hasProfilePhoto(userInfo) {
            ParticipantAvatarView(userInfo: userInfo, size: avatarSize)
              .accessibilityLabel("Show \(userInfo.user.shortDisplayName)’s photo")
              .accessibilityAddTraits(.isButton)
          } else {
            UserAvatar(userInfo: userInfo, size: avatarSize)
              .accessibilityHidden(true)
          }
        }
        .frame(width: avatarSize, height: avatarSize)
        .padding(.bottom, 4)

        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(userInfo.user.fullName)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .contextMenu {
              Button("Copy Name", systemImage: "doc.on.doc") {
                PeerInfoIOSPasteboard.copy(userInfo.user.fullName, toast: "Copied name")
              }
            }

          UserNameBadges(user: userInfo.user, spaceID: nil, size: 20)
        }
        dmSubtitle(userInfo)
      } else if isEditingInfo {
        VStack(spacing: 12) {
          Button {
            toggleEmojiPicker()
          } label: {
            ThreadIconView(
              ThreadIconDescriptor(
                emoji: draftEmoji,
                title: draftTitle,
                isReplyThread: currentChat?.isReplyThread == true,
                accessibilityLabel: draftTitle
              ),
              size: .large(92),
              shape: .circle
            )
            .overlay(alignment: .bottomTrailing) {
              Image(systemName: "face.smiling")
                .font(.footnote.weight(.semibold))
                .padding(6)
                .background(.regularMaterial, in: Circle())
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Choose thread icon")
          .emojiPicker(
            isPresented: $isEmojiPickerPresented,
            selectedEmoji: $draftEmoji
          )

          TextField("Thread Name", text: $draftTitle)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($isTitleFocused)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
              Color(uiColor: .secondarySystemGroupedBackground),
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
      } else {
        Button {
          if canEditChatInfo { startEditingChatInfo() }
        } label: {
          ThreadIconView(
            currentChat.map(ThreadIconDescriptor.init(chat:)) ?? ThreadIconDescriptor(
              emoji: nil,
              title: chatTitle,
              accessibilityLabel: chatTitle
            ),
            size: .large(92),
            shape: .circle
          )
        }
        .buttonStyle(.plain)
        .disabled(!canEditChatInfo)
        .accessibilityLabel(canEditChatInfo ? "Edit thread" : chatTitle)
        .padding(.bottom, 4)

        Text(chatTitle)
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)

        Text(PeerInfoSubtitle.thread(subject: subject, memberCount: threadMemberCount))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func dmSubtitle(_ userInfo: UserInfo) -> some View {
    switch subject.kind {
    case .bot:
      // Bot usernames are mostly noise; the status says more.
      BotInfoStatusLine(user: userInfo.user)
    case .selfChat:
      Text("Only you can see this chat")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    default:
      let focused = userInfo.focus?.isActive() == true
      if let text = PeerInfoSubtitle.person(
        focusActive: focused,
        localTime: PeerInfoPersonFields(user: userInfo.user).localTime
      ) {
        Label {
          Text(text)
        } icon: {
          if focused { Image(systemName: "moon.fill") }
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var threadMemberCount: Int? {
    let count = participantsWithMembersViewModel.effectiveUserIds.count
    return count > 0 ? count : (participantsWithMembersViewModel.participants.isEmpty ? nil : participantsWithMembersViewModel.participants.count)
  }

  private func hasProfilePhoto(_ userInfo: UserInfo) -> Bool {
    if userInfo.user.getLocalURL() != nil || userInfo.user.getRemoteURL() != nil {
      return true
    }

    if let file = userInfo.profilePhoto?.first,
       file.getLocalURL() != nil || file.getRemoteURL() != nil
    {
      return true
    }

    return false
  }

  var canSaveChatInfo: Bool {
    let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && currentChatId != 0
  }

  func startEditingChatInfo() {
    guard canEditChatInfo else { return }
    emojiPickerPresentationGeneration &+= 1
    let generation = emojiPickerPresentationGeneration
    draftTitle = chatTitle
    draftEmoji = currentChat?.emoji ?? ""
    isEditingInfo = true
    isEmojiPickerPresented = false
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      guard emojiPickerPresentationGeneration == generation,
            isEditingInfo,
            !isSavingInfo
      else { return }
      isTitleFocused = true
    }
  }

  func cancelEditingChatInfo() {
    guard !isSavingInfo else { return }
    emojiPickerPresentationGeneration &+= 1
    isTitleFocused = false
    draftTitle = ""
    draftEmoji = ""
    isEditingInfo = false
    isEmojiPickerPresented = false
  }

  func toggleEmojiPicker() {
    emojiPickerPresentationGeneration &+= 1
    let generation = emojiPickerPresentationGeneration

    if isEmojiPickerPresented {
      isEmojiPickerPresented = false
      return
    }

    isTitleFocused = false
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )

    Task { @MainActor in
      await Task.yield()
      guard emojiPickerPresentationGeneration == generation,
            isEditingInfo,
            !isSavingInfo,
            !isTitleFocused
      else { return }
      isEmojiPickerPresented = true
    }
  }

  func saveChatInfo() {
    let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { return }
    guard currentChatId != 0 else { return }

    let normalizedEmoji = draftEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
    emojiPickerPresentationGeneration &+= 1
    isTitleFocused = false
    isEmojiPickerPresented = false
    isSavingInfo = true

    Task {
      do {
        _ = try await Api.realtime.send(.updateChatInfo(
          chatID: currentChatId,
          title: trimmedTitle,
          emoji: normalizedEmoji
        ))

        await MainActor.run {
          isSavingInfo = false
          isEditingInfo = false
          draftTitle = ""
          draftEmoji = ""
        }
      } catch {
        Log.shared.error("Failed to update chat info", error: error)
        await MainActor.run {
          isSavingInfo = false
        }
      }
    }
  }

  var searchSheet: some View {
    SearchParticipantsView(
      searchText: $searchText,
      searchResults: searchResults,
      groupResults: groupSearchResults,
      isSearching: isSearchingState,
      onDebouncedInput: { value in
        guard let value else { return }
        searchUsers(query: value)
      },
      onAddParticipant: addParticipant,
      onAddGroup: addGroupParticipant,
      onCancel: {
        cancelParticipantSearch()
        isSearching = false
        searchText = ""
      }
    )
  }
}
