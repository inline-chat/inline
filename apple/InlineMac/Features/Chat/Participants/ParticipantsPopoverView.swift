import Combine
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

public struct ParticipantsPopoverView: View {
  let participants: [UserInfo]
  let currentUserId: Int64?
  let peer: Peer
  let dependencies: AppDependencies
  let onAddParticipants: (() -> Void)?
  @Binding var isPresented: Bool
  @State private var searchText = ""
  @State private var chat: Chat?
  @State private var isOwnerOrAdmin = false
  @State private var isCreator = false
  @State private var showRemoveConfirmation = false
  @State private var participantPendingRemoval: UserInfo?
  @State private var showVisibilityPicker = false
  @State private var selectedParticipantIds: Set<Int64> = []
  @State private var chatSubscription: AnyCancellable?

  public init(
    participants: [UserInfo],
    currentUserId: Int64?,
    peer: Peer,
    dependencies: AppDependencies,
    isPresented: Binding<Bool>,
    onAddParticipants: (() -> Void)? = nil
  ) {
    self.participants = participants
    self.currentUserId = currentUserId
    self.peer = peer
    self.dependencies = dependencies
    _isPresented = isPresented
    self.onAddParticipants = onAddParticipants
  }

  private var filteredParticipants: [UserInfo] {
    if searchText.isEmpty {
      return participants
    }
    return participants.filter { participant in
      let name = "\(participant.user.firstName ?? "") \(participant.user.lastName ?? "")"
        .trimmingCharacters(in: .whitespaces)
      let username = participant.user.username ?? ""
      let email = participant.user.email ?? ""

      return name.localizedCaseInsensitiveContains(searchText) ||
        username.localizedCaseInsensitiveContains(searchText) ||
        email.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var shouldShowSearch: Bool {
    participants.count >= 5
  }

  private var canManageParticipants: Bool {
    guard case .thread = peer,
          let chat,
          chat.isPublic == false
    else {
      return false
    }
    return isOwnerOrAdmin || isCreator
  }

  private var canAddParticipants: Bool {
    canManageParticipants
  }

  private var canToggleVisibility: Bool {
    guard case .thread = peer,
          let chat,
          chat.spaceId != nil,
          (isOwnerOrAdmin || isCreator)
    else {
      return false
    }
    return true
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header
      HStack {
        Text("Participants (\(participants.count))")
          .font(.system(size: 13, weight: .semibold))

        Spacer()

        if canAddParticipants {
          Button(action: {
            onAddParticipants?()
          }) {
            Image(systemName: "person.fill.badge.plus")
              .font(.system(size: 15))
              .foregroundColor(.blue)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 4)

      if canToggleVisibility, let chat {
        Button(action: {
          if chat.isPublic == true {
            let currentUserId = dependencies.auth.currentUserId
            selectedParticipantIds = currentUserId.map { [$0] } ?? []
            showVisibilityPicker = true
          } else {
            updateVisibility(isPublic: true, participantIds: [])
          }
        }) {
          HStack(spacing: 6) {
            Image(systemName: chat.isPublic == true ? "lock.fill" : "globe")
              .font(.system(size: 12))
            Text(chat.isPublic == true ? "Make Private" : "Make Public")
              .font(.system(size: 12, weight: .medium))
          }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
      }

      // Search (for 10+ participants)
      if shouldShowSearch {
        SearchField(text: $searchText, placeholder: "Search participants...")
          .padding(.horizontal, 10)
      }

      // Participant List
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(filteredParticipants, id: \.id) { participant in
            ParticipantRow(
              participant: participant,
              isCurrentUser: participant.id == currentUserId,
              canManageParticipants: canManageParticipants,
              onRequestRemove: {
                participantPendingRemoval = participant
                showRemoveConfirmation = true
              }
            )
            .padding(.horizontal, 10)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(maxHeight: shouldShowSearch ? 200 : 220)
    }
    .padding(.bottom, 4)
    .task {
      subscribeToChatUpdates()
      await loadChat()
    }
    .confirmationDialog(
      "Remove participant?",
      isPresented: $showRemoveConfirmation,
      presenting: participantPendingRemoval,
      actions: { participant in
        Button("Cancel", role: .cancel) {}
        Button("Remove", role: .destructive) {
          removeParticipant(userId: participant.user.id)
        }
      },
      message: { participant in
        Text("Remove \(participant.user.shortDisplayName) from this chat?")
      }
    )
    .sheet(isPresented: $showVisibilityPicker) {
      if let chat, let spaceId = chat.spaceId {
        ChatVisibilityParticipantsSheet(
          spaceId: spaceId,
          selectedUserIds: $selectedParticipantIds,
          db: dependencies.database,
          isPresented: $showVisibilityPicker,
          onConfirm: { participantIds in
            updateVisibility(isPublic: false, participantIds: Array(participantIds))
          }
        )
      }
    }
  }

  private func loadChat() async {
    guard case let .thread(chatId) = peer else { return }

    do {
      let loadedChat = try await dependencies.database.dbWriter.read { db in
        try Chat.fetchOne(db, id: chatId)
      }
      chat = loadedChat

      guard let loadedChat, let currentUserId = dependencies.auth.currentUserId else {
        isOwnerOrAdmin = false
        isCreator = false
        return
      }

      // Creator status shouldn't depend on the chat having a space.
      isCreator = loadedChat.createdBy == currentUserId

      // Owner/admin only makes sense for space-backed chats.
      if let spaceId = loadedChat.spaceId {
        let member = try await dependencies.database.dbWriter.read { db in
          try Member
            .filter(Column("spaceId") == spaceId)
            .filter(Column("userId") == currentUserId)
            .fetchOne(db)
        }
        isOwnerOrAdmin = member?.role == .owner || member?.role == .admin
      } else {
        isOwnerOrAdmin = false
      }
    } catch {
      Log.shared.error("Failed to load chat for participants", error: error)
    }
  }

  @MainActor
  private func subscribeToChatUpdates() {
    guard chatSubscription == nil else { return }
    guard case let .thread(chatId) = peer else { return }

    chatSubscription = ObjectCache.shared.getChatPublisher(id: chatId)
      .sink { updatedChat in
        DispatchQueue.main.async {
          self.chat = updatedChat
        }
      }
  }

  private func updateVisibility(isPublic: Bool, participantIds: [Int64]) {
    guard case let .thread(chatId) = peer else { return }

    Task {
      do {
        _ = try await Api.realtime.send(.updateChatVisibility(
          chatID: chatId,
          isPublic: isPublic,
          participantIDs: participantIds
        ))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after visibility update", error: error)
        }
      } catch {
        Log.shared.error("Failed to update chat visibility", error: error)
      }
    }
  }

  private func removeParticipant(userId: Int64) {
    guard case let .thread(chatId) = peer else { return }
    if let currentUserId, currentUserId == userId { return }

    Task {
      do {
        _ = try await Api.realtime.send(.removeChatParticipant(chatID: chatId, userID: userId))
        do {
          try await Api.realtime.send(.getChatParticipants(chatID: chatId))
        } catch {
          Log.shared.error("Failed to refetch chat participants after removal", error: error)
        }
      } catch {
        Log.shared.error("Failed to remove participant", error: error)
      }
    }
  }
}

private struct ParticipantRow: View {
  let participant: UserInfo
  let isCurrentUser: Bool
  let canManageParticipants: Bool
  let onRequestRemove: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      UserAvatar(user: participant.user, size: 24)

      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Text(displayName)
            .font(.system(size: 12, weight: .medium))

          if isCurrentUser {
            Text("(You)")
              .font(.system(size: 10))
              .foregroundColor(.secondary)
          }
        }
      }

      Spacer()

      if canManageParticipants, !isCurrentUser {
        Button(action: onRequestRemove) {
          Image(systemName: "minus.circle.fill")
            .font(.system(size: 14))
            .foregroundColor(.red)
            .opacity(isHovered ? 0.9 : 0.0)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isHovered)
        .accessibilityLabel("Remove participant")
      }
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovered = hovering
    }
    .contextMenu {
      if canManageParticipants, !isCurrentUser {
        Button(role: .destructive, action: onRequestRemove) {
          Label("Remove Participant", systemImage: "minus.circle")
        }
      }
    }
  }

  private var displayName: String {
    let name = "\(participant.user.firstName ?? "") \(participant.user.lastName ?? "")"
      .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? (participant.user.username ?? participant.user.email ?? "Unknown") : name
  }
}

private struct SearchField: View {
  @Binding var text: String
  let placeholder: String

  var body: some View {
    HStack {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
        .font(.system(size: 12))

      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(4)
  }
}
