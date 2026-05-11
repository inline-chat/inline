import InlineKit
import Logger
import SwiftUI

struct ChatToolbarParticipantsButton: View {
  let peer: Peer
  let dependencies: AppDependencies
  let toolbarState: ChatToolbarState

  @StateObject private var participantsViewModel: ChatParticipantsWithMembersViewModel

  init(peer: Peer, dependencies: AppDependencies, toolbarState: ChatToolbarState) {
    self.peer = peer
    self.dependencies = dependencies
    self.toolbarState = toolbarState

    switch peer {
      case let .thread(chatId):
        _participantsViewModel = StateObject(
          wrappedValue: ChatParticipantsWithMembersViewModel(db: dependencies.database, chatId: chatId)
        )
      default:
        _participantsViewModel = StateObject(
          wrappedValue: ChatParticipantsWithMembersViewModel(db: dependencies.database, chatId: -1)
        )
    }
  }

  var body: some View {
    ParticipantsButton(participants: participantsViewModel.participants) {
      toolbarState.presentParticipantsPopover()
    }
    .accessibilityLabel("Participants")
    .onAppear {
      toolbarState.handleAppear(.participants)
    }
    .onDisappear {
      toolbarState.handleDisappear(.participants)
    }
    .modifier(ChatToolbarParticipantsPresentations(
      peer: peer,
      dependencies: dependencies,
      toolbarState: toolbarState,
      anchor: .button(.participants),
      participantsViewModel: participantsViewModel
    ))
  }
}

struct ChatToolbarParticipantsTitlePresentations: ViewModifier {
  let peer: Peer
  let dependencies: AppDependencies
  let toolbarState: ChatToolbarState

  @State private var participantsViewModel: ChatParticipantsWithMembersViewModel?
  @State private var chat: Chat?
  @State private var task: Task<Void, Never>?

  init(peer: Peer, dependencies: AppDependencies, toolbarState: ChatToolbarState) {
    self.peer = peer
    self.dependencies = dependencies
    self.toolbarState = toolbarState
  }

  func body(content: Content) -> some View {
    content
      .popover(isPresented: Binding(
        get: { toolbarState.presentation == .participantsPopover(.title) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .participantsPopover(.title) else { return }
          toolbarState.dismissPresentation()
        }
      ), arrowEdge: .bottom) {
        if let participantsViewModel {
          ParticipantsToolbarPopoverContent(
            participantsViewModel: participantsViewModel,
            peer: peer,
            dependencies: dependencies,
            isPresented: Binding(
              get: { toolbarState.presentation == .participantsPopover(.title) },
              set: { isPresented in
                guard !isPresented, toolbarState.presentation == .participantsPopover(.title) else { return }
                toolbarState.dismissPresentation()
              }
            ),
            onAddParticipants: {
              toolbarState.presentAddParticipants(from: .title)
            }
          )
        } else {
          ProgressView()
            .controlSize(.small)
            .frame(width: 180, height: 240)
        }
      }
      .sheet(isPresented: Binding(
        get: { toolbarState.presentation == .addParticipants(.title) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .addParticipants(.title) else { return }
          toolbarState.dismissPresentation()
        }
      )) {
        if let participantsViewModel, let chat {
          AddParticipantsContent(
            chat: chat,
            participants: participantsViewModel.participants,
            dependencies: dependencies,
            isPresented: Binding(
              get: { toolbarState.presentation == .addParticipants(.title) },
              set: { isPresented in
                guard !isPresented, toolbarState.presentation == .addParticipants(.title) else { return }
                toolbarState.dismissPresentation()
              }
            )
          )
        }
      }
      .onChange(of: toolbarState.presentation, initial: true) { _, presentation in
        handlePresentation(presentation)
      }
      .onChange(of: peer.toString()) { _, _ in
        reset()
      }
      .onDisappear {
        task?.cancel()
      }
  }

  private func handlePresentation(_ presentation: ChatToolbarState.Presentation?) {
    guard presentation == .participantsPopover(.title) || presentation == .addParticipants(.title) else { return }
    guard let participantsViewModel = ensureParticipantsViewModel() else { return }

    task?.cancel()
    task = Task {
      if case .thread = peer {
        await participantsViewModel.refetchParticipants()
      }

      guard !Task.isCancelled else { return }
      if presentation == .addParticipants(.title) {
        await loadChat()
      }
    }
  }

  private func ensureParticipantsViewModel() -> ChatParticipantsWithMembersViewModel? {
    if let participantsViewModel {
      return participantsViewModel
    }

    guard case let .thread(chatId) = peer else { return nil }
    let viewModel = ChatParticipantsWithMembersViewModel(db: dependencies.database, chatId: chatId)
    participantsViewModel = viewModel
    return viewModel
  }

  private func loadChat() async {
    guard case let .thread(chatId) = peer else { return }

    do {
      let loadedChat = try await dependencies.database.reader.read { db in
        try Chat.fetchOne(db, id: chatId)
      }
      guard !Task.isCancelled else { return }
      chat = loadedChat
    } catch {
      Log.shared.error("Failed to load chat for toolbar participants", error: error)
    }
  }

  private func reset() {
    task?.cancel()
    task = nil
    participantsViewModel = nil
    chat = nil
  }
}

private struct ChatToolbarParticipantsPresentations: ViewModifier {
  let peer: Peer
  let dependencies: AppDependencies
  let toolbarState: ChatToolbarState
  let anchor: ChatToolbarState.Anchor
  @ObservedObject var participantsViewModel: ChatParticipantsWithMembersViewModel

  @State private var chat: Chat?
  @State private var task: Task<Void, Never>?

  func body(content: Content) -> some View {
    let presentation = toolbarState.presentation

    content
      .popover(isPresented: Binding(
        get: { presentation == .participantsPopover(anchor) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .participantsPopover(anchor) else { return }
          toolbarState.dismissPresentation()
        }
      ), arrowEdge: .bottom) {
        ParticipantsToolbarPopoverContent(
          participantsViewModel: participantsViewModel,
          peer: peer,
          dependencies: dependencies,
          isPresented: Binding(
            get: { toolbarState.presentation == .participantsPopover(anchor) },
            set: { isPresented in
              guard !isPresented, toolbarState.presentation == .participantsPopover(anchor) else { return }
              toolbarState.dismissPresentation()
            }
          ),
          onAddParticipants: {
            toolbarState.presentAddParticipants(from: anchor)
          }
        )
      }
      .sheet(isPresented: Binding(
        get: { presentation == .addParticipants(anchor) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .addParticipants(anchor) else { return }
          toolbarState.dismissPresentation()
        }
      )) {
        if let chat {
          AddParticipantsContent(
            chat: chat,
            participants: participantsViewModel.participants,
            dependencies: dependencies,
            isPresented: Binding(
              get: { toolbarState.presentation == .addParticipants(anchor) },
              set: { isPresented in
                guard !isPresented, toolbarState.presentation == .addParticipants(anchor) else { return }
                toolbarState.dismissPresentation()
              }
            )
          )
        }
      }
      .onChange(of: toolbarState.presentation, initial: true) { _, presentation in
        handlePresentation(presentation)
      }
      .onDisappear {
        task?.cancel()
      }
  }

  private func handlePresentation(_ presentation: ChatToolbarState.Presentation?) {
    guard presentation == .participantsPopover(anchor) || presentation == .addParticipants(anchor) else { return }

    task?.cancel()
    task = Task {
      if case .thread = peer {
        await participantsViewModel.refetchParticipants()
      }

      guard !Task.isCancelled else { return }
      if presentation == .addParticipants(anchor) {
        await loadChat()
      }
    }
  }

  private func loadChat() async {
    guard case let .thread(chatId) = peer else { return }

    do {
      let loadedChat = try await dependencies.database.reader.read { db in
        try Chat.fetchOne(db, id: chatId)
      }
      guard !Task.isCancelled else { return }
      chat = loadedChat
    } catch {
      Log.shared.error("Failed to load chat for toolbar participants", error: error)
    }
  }
}

private struct ParticipantsToolbarPopoverContent: View {
  @ObservedObject var participantsViewModel: ChatParticipantsWithMembersViewModel
  let peer: Peer
  let dependencies: AppDependencies
  let isPresented: Binding<Bool>
  let onAddParticipants: () -> Void

  var body: some View {
    ParticipantsPopoverView(
      participants: participantsViewModel.participants,
      currentUserId: dependencies.auth.currentUserId,
      peer: peer,
      dependencies: dependencies,
      isPresented: isPresented,
      onAddParticipants: onAddParticipants
    )
    .frame(width: 180, height: 240)
  }
}

private struct AddParticipantsContent: View {
  let chat: Chat
  let participants: [UserInfo]
  let dependencies: AppDependencies
  let isPresented: Binding<Bool>

  var body: some View {
    if let spaceId = chat.spaceId {
      AddParticipantsSheet(
        chatId: chat.id,
        spaceId: spaceId,
        currentParticipants: participants,
        db: dependencies.database,
        isPresented: isPresented
      )
    } else {
      AddHomeParticipantsSheet(
        chatId: chat.id,
        currentUserId: dependencies.auth.currentUserId,
        currentParticipants: participants,
        db: dependencies.database,
        isPresented: isPresented
      )
    }
  }
}
