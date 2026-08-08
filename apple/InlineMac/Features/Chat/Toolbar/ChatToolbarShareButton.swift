import AppKit
import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI

struct ChatToolbarShareButton: View {
  let peer: Peer
  let dependencies: AppDependencies
  let toolbarState: ChatToolbarState

  @StateObject private var model: ChatToolbarShareModel
  @State private var isVisibilityPickerPresented = false
  @State private var selectedParticipantIds: Set<Int64> = []
  @State private var transcriptTask: Task<Void, Never>?
  @State private var pendingTranscript: ChatTranscriptExport?
  @State private var showTranscriptScope = false

  init(peer: Peer, dependencies: AppDependencies, toolbarState: ChatToolbarState) {
    self.peer = peer
    self.dependencies = dependencies
    self.toolbarState = toolbarState
    _model = StateObject(wrappedValue: ChatToolbarShareModel(
      peer: peer,
      currentUserId: dependencies.auth.currentUserId,
      db: dependencies.database
    ))
  }

  var body: some View {
    Menu {
      Button("Copy Markdown", systemImage: "doc.on.doc") {
        prepareTranscript()
      }
      .disabled(transcriptTask != nil)

      Divider()

      if model.state.spaceId != nil {
        Button {
          toggleVisibility()
        } label: {
          Label(
            model.state.isPublic ? "Make Private" : "Make Public",
            systemImage: model.state.isPublic ? "lock.fill" : "globe"
          )
        }
        .disabled(!model.state.canToggleVisibility)
      }

      Button {
        toolbarState.presentAddParticipants()
      } label: {
        Label("Add Participant", systemImage: "person.badge.plus")
      }
      .disabled(!model.state.canAddParticipants)

      Divider()

      Button {
        copyPrivateLink()
      } label: {
        ChatShareMenuLabel(
          title: "Copy Link",
          description: "Only people who can access this chat can use this link.",
          systemImage: "link"
        )
      }

      Button {} label: {
        ChatShareMenuLabel(
          title: "Copy Public Link",
          description: "Coming soon",
          systemImage: "globe"
        )
      }
      .disabled(true)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
        .labelStyle(.iconOnly)
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("Share")
    .help("Share")
    .sheet(isPresented: $isVisibilityPickerPresented) {
      if let spaceId = model.state.spaceId {
        ChatVisibilityParticipantsSheet(
          spaceId: spaceId,
          selectedUserIds: $selectedParticipantIds,
          db: dependencies.database,
          isPresented: $isVisibilityPickerPresented,
          onConfirm: { participantIds in
            updateVisibility(isPublic: false, participantIds: Array(participantIds))
          }
        )
      }
    }
    .confirmationDialog(
      "How much should be copied?",
      isPresented: $showTranscriptScope,
      titleVisibility: .visible
    ) {
      if let pendingTranscript {
        Button {
          copyTranscript(pendingTranscript)
        } label: {
          Text("Copy Latest \(pendingTranscript.messageCount) Messages")
        }
        Button("Copy Entire Chat") {
          prepareEntireTranscript(startingWith: pendingTranscript)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This chat has more messages than the default transcript.")
    }
    .onDisappear {
      transcriptTask?.cancel()
    }
  }

  @MainActor
  private func prepareTranscript() {
    guard transcriptTask == nil else { return }
    transcriptTask = Task(priority: .userInitiated) { @MainActor in
      defer { transcriptTask = nil }
      ToastCenter.shared.showLoading("Preparing…")

      do {
        let transcript = try await ChatTranscriptExporter.latest(
          peer: peer,
          realtime: dependencies.realtimeV2
        )
        try Task.checkCancellation()
        ToastCenter.shared.dismiss()

        if transcript.hasMore {
          pendingTranscript = transcript
          showTranscriptScope = true
        } else {
          copyTranscript(transcript)
        }
      } catch is CancellationError {
        ToastCenter.shared.dismiss()
      } catch {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showError("Failed to prepare transcript")
      }
    }
  }

  @MainActor
  private func prepareEntireTranscript(startingWith latest: ChatTranscriptExport) {
    guard transcriptTask == nil else { return }
    transcriptTask = Task(priority: .userInitiated) { @MainActor in
      defer { transcriptTask = nil }
      ToastCenter.shared.showLoading("Preparing…")

      do {
        let transcript = try await ChatTranscriptExporter.all(
          peer: peer,
          startingWith: latest,
          realtime: dependencies.realtimeV2
        )
        try Task.checkCancellation()
        ToastCenter.shared.dismiss()
        copyTranscript(transcript)
      } catch is CancellationError {
        ToastCenter.shared.dismiss()
      } catch {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showError("Failed to prepare transcript")
      }
    }
  }

  @MainActor
  private func copyTranscript(_ transcript: ChatTranscriptExport) {
    let pasteboard = NSPasteboard.general
    let previousString = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(transcript.markdown, forType: .string) else {
      if let previousString {
        pasteboard.setString(previousString, forType: .string)
      }
      ToastCenter.shared.showError("Failed to copy transcript")
      return
    }
    pendingTranscript = nil
    ToastCenter.shared.showSuccess("Copied as Markdown")
  }

  private func toggleVisibility() {
    guard model.state.canToggleVisibility else { return }

    if model.state.isPublic {
      selectedParticipantIds = dependencies.auth.currentUserId.map { [$0] } ?? []
      isVisibilityPickerPresented = true
    } else {
      updateVisibility(isPublic: true, participantIds: [])
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
          Log.shared.error("Failed to refresh participants after visibility update", error: error)
        }
      } catch {
        Log.shared.error("Failed to update chat visibility from share menu", error: error)
        ToastCenter.shared.showError("Failed to update chat visibility")
      }
    }
  }

  private func copyPrivateLink() {
    guard case let .thread(chatId) = peer,
          let url = InlineDeepLink.chat(id: chatId).webURL
    else {
      ToastCenter.shared.showError("Failed to copy link")
      return
    }

    let pasteboard = NSPasteboard.general
    let previousString = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(url.absoluteString, forType: .string) else {
      if let previousString {
        pasteboard.setString(previousString, forType: .string)
      }
      ToastCenter.shared.showError("Failed to copy link")
      return
    }
    ToastCenter.shared.showSuccess("Copied link")
  }
}

private struct ChatShareMenuLabel: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let systemImage: String

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: systemImage)
    }
  }
}

@MainActor
private final class ChatToolbarShareModel: ObservableObject {
  @Published private(set) var state = ChatToolbarShareState()

  private var stateCancellable: AnyCancellable?

  init(peer: Peer, currentUserId: Int64?, db: AppDatabase) {
    db.warnIfInMemoryDatabaseForObservation("ChatToolbarShareModel.state")
    stateCancellable = ValueObservation
      .tracking { database in
        guard let chatId = peer.asThreadId(),
              let chat = try Chat.fetchOne(database, id: chatId)
        else {
          return ChatToolbarShareState()
        }

        return try ChatToolbarShareState(
          chat: chat,
          currentUserId: currentUserId,
          db: database
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] state in
          guard self?.state != state else { return }
          self?.state = state
        }
      )
  }
}

private struct ChatToolbarShareState: Equatable {
  var spaceId: Int64?
  var isPublic = false
  var canToggleVisibility = false
  var canAddParticipants = false

  init() {}

  init(chat: Chat, currentUserId: Int64?, db: Database) throws {
    spaceId = chat.spaceId
    isPublic = chat.isPublic == true

    guard chat.parentChatId == nil, let currentUserId else { return }

    let isCreator = chat.createdBy == currentUserId
    let isOwnerOrAdmin = try chat.spaceId.flatMap { spaceId in
      try Member
        .filter(Column("spaceId") == spaceId)
        .filter(Column("userId") == currentUserId)
        .fetchOne(db)
        .map { $0.role == .owner || $0.role == .admin }
    } ?? false
    let canManage = isCreator || isOwnerOrAdmin

    canToggleVisibility = chat.spaceId != nil && canManage
    canAddParticipants = !isPublic && canManage
  }
}
