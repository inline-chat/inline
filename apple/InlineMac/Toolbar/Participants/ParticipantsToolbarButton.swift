import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI
import Combine

public struct ParticipantsToolbarButton: View {
  let peer: Peer
  let dependencies: AppDependencies
  @State private var isPopoverPresented = false
  @State private var showAddParticipants = false
  @State private var chat: Chat?
  @StateObject private var participantsViewModel: ChatParticipantsViewModel
  
  public init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    
    switch peer {
    case .thread(let chatId):
      _participantsViewModel = StateObject(wrappedValue: ChatParticipantsViewModel(db: dependencies.database, chatId: chatId))
    default:
      // For non-thread peers, create empty view model
      _participantsViewModel = StateObject(wrappedValue: ChatParticipantsViewModel(db: dependencies.database, chatId: -1))
    }
  }
  
  private var displayParticipants: [UserInfo] {
    // Show all participants including current user
    return participantsViewModel.participants
  }
  
  public var body: some View {
    Button(action: {
      isPopoverPresented.toggle()
    }) {
      ParticipantAvatarStack(participants: Array(displayParticipants.prefix(3)))
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
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
    .sheet(isPresented: $showAddParticipants) {
      if let chat, let spaceId = chat.spaceId {
        AddParticipantsSheet(
          chatId: chat.id,
          spaceId: spaceId,
          currentParticipants: participantsViewModel.participants,
          db: dependencies.database,
          isPresented: $showAddParticipants
        )
      }
    }
    .task {
      // Refetch participants for private thread chats to ensure data is available locally
      if case .thread = peer, peer.isPrivate {
        await participantsViewModel.refetchParticipants()
      }
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
      Log.shared.error("Failed to load chat for add participants", error: error)
    }
  }
}