import Combine
import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

public struct ParticipantsToolbarButton: View {
  let peer: Peer
  let dependencies: AppDependencies
  @State private var isPopoverPresented = false
  @State private var showAddParticipants = false
  @State private var chat: Chat?
  @StateObject private var participantsViewModel: ChatParticipantsWithMembersViewModel

  public init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies

    switch peer {
    case let .thread(chatId):
      _participantsViewModel = StateObject(
        wrappedValue: ChatParticipantsWithMembersViewModel(db: dependencies.database, chatId: chatId)
      )
    default:
      // For non-thread peers, create empty view model
      _participantsViewModel = StateObject(
        wrappedValue: ChatParticipantsWithMembersViewModel(db: dependencies.database, chatId: -1)
      )
    }
  }

  private var displayParticipants: [UserInfo] {
    // Show all participants including current user
    return participantsViewModel.participants
  }

  public var body: some View {
    ParticipantsButton(participants: displayParticipants) {
      isPopoverPresented.toggle()
    }
    .accessibilityLabel("Participants")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      participantsPresentationContent
    }
    .sheet(isPresented: $showAddParticipants) {
      if let chat {
        if let spaceId = chat.spaceId {
          AddParticipantsSheet(
            chatId: chat.id,
            spaceId: spaceId,
            currentParticipants: participantsViewModel.participants,
            db: dependencies.database,
            isPresented: $showAddParticipants
          )
        } else {
          AddHomeParticipantsSheet(
            chatId: chat.id,
            currentUserId: dependencies.auth.currentUserId,
            currentParticipants: participantsViewModel.participants,
            db: dependencies.database,
            isPresented: $showAddParticipants
          )
        }
      }
    }
    .task {
      // Refetch participants for thread chats to ensure data is available locally
      if case .thread = peer {
        await participantsViewModel.refetchParticipants()
      }
      await loadChat()
    }
  }

  @ViewBuilder
  private var participantsPresentationContent: some View {
    ParticipantsPopoverView(
      participants: participantsViewModel.participants,
      currentUserId: dependencies.auth.currentUserId,
      peer: peer,
      dependencies: dependencies,
      isPresented: $isPopoverPresented,
      onAddParticipants: {
        showAddParticipants = true
      }
    )
    .frame(width: 180, height: 240)
  }

  private func loadChat() async {
    guard case let .thread(chatId) = peer else { return }

    do {
      chat = try await dependencies.database.dbWriter.read { db in
        try Chat.fetchOne(db, id: chatId)
      }
    } catch {
      Log.shared.error("Failed to load chat for add participants", error: error)
    }
  }
}

/// Button-only participants toolbar item. Presentation is owned by the caller.
public struct ParticipantsButton: View {
  private let participants: [UserInfo]
  private let action: () -> Void

  public init(participants: [UserInfo], action: @escaping () -> Void) {
    self.participants = participants
    self.action = action
  }

  private var visibleParticipants: [UserInfo] {
    Array(participants.prefix(3))
  }

  private var buttonWidth: CGFloat {
    let count = visibleParticipants.count
    let width = CGFloat(count) * 24 - CGFloat(max(0, count - 1)) * 6 + 8
    return max(32, width)
  }

  public var body: some View {
    Button(action: action) {
      Label("Participants", systemImage: "person.2")
        .frame(width: buttonWidth)
        .opacity(0)
        .overlay {
          ParticipantAvatarStack(participants: visibleParticipants)
        }
    }
  }
}
