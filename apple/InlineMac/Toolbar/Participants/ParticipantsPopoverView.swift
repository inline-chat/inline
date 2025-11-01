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
    participants.count >= 10
  }

  private var canAddParticipants: Bool {
    guard case .thread = peer,
          let chat,
          chat.isPublic == false,
          chat.spaceId != nil
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
              isCurrentUser: participant.id == currentUserId
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
      await loadChat()
    }
  }

  private func loadChat() async {
    guard case let .thread(chatId) = peer else { return }

    do {
      chat = try await dependencies.database.dbWriter.read { db in
        try Chat.fetchOne(db, id: chatId)
      }
    } catch {
      Log.shared.error("Failed to load chat for participants", error: error)
    }
  }
}

private struct ParticipantRow: View {
  let participant: UserInfo
  let isCurrentUser: Bool

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
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
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
