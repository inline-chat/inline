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
          !excludedUserIDs.contains($0.user.id) &&
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
        let local = InviteDirectory.mergedUsers(
          local: try await InviteDirectory.localUsers(query: query, database: database),
          remote: [],
          excluding: excludedUserIDs
        )
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
    if router.tracksHistory {
      router.resetTransientPresentation()
      router.openPrimaryDestination(
        .chatMessage(peer: chatItem.peerId, messageID: message.messageId)
      )
      return
    }

    let targetTab = router.selectedTab.currentChatsTab
    router.selectedTab = targetTab
    router.pop(for: targetTab)

    if !nav.pathComponents.isEmpty {
      nav.pop()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      NotificationCenter.default.post(
        name: Notification.Name("ScrollToRepliedMessage"),
        object: nil,
        userInfo: [
          "repliedToMessageId": message.messageId,
          "chatId": message.chatId,
        ]
      )
    }
  }

  func formatSectionDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
      return "Today"
    } else if calendar.isDateInYesterday(date) {
      return "Yesterday"
    } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"
      return formatter.string(from: date)
    } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d"
      return formatter.string(from: date)
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d, yyyy"
      return formatter.string(from: date)
    }
  }

  @ViewBuilder
  var chatInfoHeader: some View {
    VStack {
      if isDM, let userInfo = chatItem.userInfo {
        let avatarSize: CGFloat = 82
        if hasProfilePhoto(userInfo) {
          ParticipantAvatarView(userInfo: userInfo, size: avatarSize)
            .frame(width: avatarSize, height: avatarSize)
        } else {
          UserAvatar(userInfo: userInfo, size: avatarSize)
            .frame(width: avatarSize, height: avatarSize)
        }
        VStack(spacing: -3) {
          Text(userInfo.user.firstName ?? "User")
            .font(.title2)
            .fontWeight(.semibold)
          if let username = userInfo.user.username {
            Text("@\(username)")
              .font(.callout)
              .foregroundColor(.secondary)
          } else {
            Text(userInfo.user.firstName ?? "user")
              .font(.callout)
              .foregroundColor(.secondary)
          }
        }
      } else {
        if isEditingInfo {
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
                size: .large(100),
                shape: .circle
              )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose chat emoji")
            .emojiPicker(
              isPresented: $isEmojiPickerPresented,
              selectedEmoji: $draftEmoji
            )

            TextField("Chat Title", text: $draftTitle)
              .font(.title2)
              .fontWeight(.semibold)
              .multilineTextAlignment(.center)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
              .focused($isTitleFocused)
          }
        } else {
          ThreadIconView(
            currentChat.map(ThreadIconDescriptor.init(chat:)) ?? ThreadIconDescriptor(
              emoji: nil,
              title: chatTitle,
              accessibilityLabel: chatTitle
            ),
            size: .large(100),
            shape: .circle
          )

          Text(chatTitle)
            .font(.title2)
            .fontWeight(.semibold)
        }
      }
    }
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
    selectedTab = .info
    draftTitle = chatTitle
    draftEmoji = currentChat?.emoji ?? ""
    isEditingInfo = true
    isEmojiPickerPresented = false
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(100))
      guard emojiPickerPresentationGeneration == generation,
            isEditingInfo,
            selectedTab == .info,
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

  @ViewBuilder
  var chatInfoContent: some View {
    if isPrivate {
      privateChatSection

    } else {
      publicChatSection
    }

    if !documentsViewModel.documentMessages.isEmpty {
      documentsSection
    }
  }

  @ViewBuilder
  var privateChatSection: some View {
    Section {
      if let userInfo = chatItem.userInfo {
        ProfileRow(userInfo: userInfo, isChatInfo: true)
      }
    }
  }

  @ViewBuilder
  var publicChatSection: some View {
    Section {
      Label("Type", systemImage: currentChat?.isPublic != true ? "lock.fill" : "person.2.fill")

      Spacer()

      Text(currentChat?.isPublic != true ? "Private" : "Public")
    }

    if currentChat?.isPublic != true {
      participantsSection
    }
  }

  @ViewBuilder
  var participantsSection: some View {
    Section("Participants") {
      if isOwnerOrAdmin, isPrivate {
        Button(action: {
          isSearching = true
        }) {
          Label("Add Participant", systemImage: "person.badge.plus")
        }
      }
      ForEach(participantsWithMembersViewModel.participants) { userInfo in
        ProfileRow(userInfo: userInfo, isChatInfo: true)
          .swipeActions {
            if isOwnerOrAdmin, isPrivate {
              Button(role: .destructive, action: {
                guard currentChatId != 0 else {
                  Log.shared.error("No chat ID found when trying to remove participant")
                  return
                }
                Task {
                  do {
                    try await Api.realtime.send(.removeChatParticipant(
                      chatID: currentChatId,
                      userID: userInfo.user.id
                    ))
                  } catch {
                    Log.shared.error("Failed to remove participant", error: error)
                  }
                }
              }) {
                Text("Remove")
              }
            }
          }
      }

      ForEach(participantsWithMembersViewModel.groupParticipants) { group in
        HStack(spacing: 10) {
          Image(systemName: "person.3.fill")
            .foregroundStyle(.white)
            .scaledFrame(width: 32, height: 32)
            .background(Color.accentColor)
            .clipShape(Circle())

          VStack(alignment: .leading, spacing: 2) {
            Text(group.name)
            Text(group.memberCount == 1 ? "1 person" : "\(group.memberCount) people")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .swipeActions {
          if isOwnerOrAdmin, isPrivate {
            Button(role: .destructive, action: {
              removeGroupParticipant(group)
            }) {
              Text("Remove")
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  var documentsSection: some View {
    ForEach(documentsViewModel.documentMessages, id: \.id) { documentMessage in
      DocumentRow(
        documentMessage: documentMessage,
        chatId: currentChatId == 0 ? nil : currentChatId
      )
    }
  }

  private func createFullMessage(from documentInfo: DocumentInfo) -> FullMessage? {
    let message = Message(
      messageId: documentInfo.document.documentId,
      fromId: 1,
      date: documentInfo.document.date,
      text: nil,
      peerUserId: nil,
      peerThreadId: currentChatId == 0 ? nil : currentChatId,
      chatId: currentChatId,
      documentId: documentInfo.document.id
    )

    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  @ViewBuilder
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
