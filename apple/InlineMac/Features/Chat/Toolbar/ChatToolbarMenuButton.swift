import Auth
import Combine
import GRDB
import InlineKit
import SwiftUI

struct ChatToolbarMenuButton: View {
  let peer: Peer
  let dependencies: AppDependencies

  @Environment(\.realtimeV2) private var realtimeV2

  @StateObject private var model: ChatToolbarMenuModel
  @State private var showRenameSheet = false
  @State private var showMoveToSpaceSheet = false
  @State private var showMoveOutConfirm = false
  @State private var pendingDestructiveAction: ChatDestructiveAction?
  @State private var loadHistoryTask: Task<Void, Never>?

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    _model = StateObject(wrappedValue: ChatToolbarMenuModel(peer: peer, db: dependencies.database))
  }

  var body: some View {
    Menu {
      if peer.isThread, model.state.canRename {
        Button("Rename Chat...", systemImage: "pencil") {
          showRenameSheet = true
        }
      }

      if peer.isThread {
        if model.state.chatSpaceId != nil {
          Button("Move Out of Space...", systemImage: "tray.and.arrow.up") {
            showMoveOutConfirm = true
          }
        } else {
          Button("Move to Space...", systemImage: "tray.and.arrow.down") {
            showMoveToSpaceSheet = true
          }
        }
      }

      if peer.isThread, model.state.isSidebarVisible == false {
        Button("Keep in Sidebar", systemImage: "sidebar.left") {
          keepInSidebar()
        }
      }

      Button("Load chat history", systemImage: "arrow.down.circle") {
        loadLast1000Messages()
      }
      .disabled(loadHistoryTask != nil)

      Divider()

      Button(
        model.state.isPinned ? "Unpin" : "Pin",
        systemImage: model.state.isPinned ? "pin.slash.fill" : "pin.fill"
      ) {
        Task(priority: .userInitiated) {
          try await DataManager.shared.updateDialog(
            peerId: peer,
            pinned: !model.state.isPinned,
            spaceId: dependencies.activeSpaceId
          )
        }
      }

      Button(
        model.state.isArchived ? "Unarchive" : "Archive",
        systemImage: "archivebox.fill"
      ) {
        Task(priority: .userInitiated) {
          try await DataManager.shared.updateDialog(
            peerId: peer,
            archived: !model.state.isArchived,
            spaceId: dependencies.activeSpaceId
          )
        }
      }

      if let destructiveAction = model.state.destructiveAction {
        Divider()

        Button(destructiveAction.title, systemImage: destructiveAction.systemImage, role: .destructive) {
          pendingDestructiveAction = destructiveAction
        }
      }
    } label: {
      Image(systemName: "info.circle")
    } primaryAction: {
      openChatInfo()
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("Chat Info")
    .help("Chat Info")
    .sheet(isPresented: $showRenameSheet) {
      RenameChatSheet(peer: peer)
    }
    .sheet(isPresented: $showMoveToSpaceSheet) {
      if let chatId = peer.asThreadId() {
        MoveThreadToSpaceSheet(chatId: chatId, nav2: dependencies.nav2, nav3: dependencies.nav3)
      }
    }
    .confirmationDialog(
      "Move this thread out of the space?",
      isPresented: $showMoveOutConfirm,
      titleVisibility: .visible
    ) {
      Button("Move to Home") {
        moveThreadToHome()
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert(
      pendingDestructiveAction?.title ?? "Confirm",
      isPresented: destructiveConfirmationPresented,
      presenting: pendingDestructiveAction
    ) { action in
      Button("Cancel", role: .cancel) {
        pendingDestructiveAction = nil
      }

      Button(action.shortTitle, role: .destructive) {
        performDestructiveAction(action)
      }
    } message: { action in
      Text(action.confirmationMessage(chatTitle: model.state.title))
    }
    .onDisappear {
      cancelHistoryLoad()
    }
  }

  private var destructiveConfirmationPresented: Binding<Bool> {
    Binding {
      pendingDestructiveAction != nil
    } set: { isPresented in
      if isPresented == false {
        pendingDestructiveAction = nil
      }
    }
  }

  private func openChatInfo() {
    dependencies.openChatInfo(peer: peer)
  }

  private func keepInSidebar() {
    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.showChatInSidebar(peerId: peer))
      } catch {
        await MainActor.run {
          ToastCenter.shared.showError("Failed to keep chat in sidebar")
        }
      }
    }
  }

  @MainActor
  private func loadLast1000Messages() {
    guard loadHistoryTask == nil else { return }

    let targetMessageCount = 1_000
    let batchSize: Int32 = 100

    loadHistoryTask = Task(priority: .userInitiated) { @MainActor in
      defer {
        loadHistoryTask = nil
      }

      ToastCenter.shared.showLoading(
        loadingHistoryMessage(loaded: 0, target: targetMessageCount),
        actionTitle: "Cancel",
        action: { cancelHistoryLoad() }
      )

      do {
        let loadedMessages = try await fetchHistoryInBatches(
          targetCount: targetMessageCount,
          batchSize: batchSize
        )
        try Task.checkCancellation()

        ToastCenter.shared.dismiss()
        if loadedMessages > 0 {
          ToastCenter.shared.showSuccess("Loaded \(loadedMessages) messages")
        } else {
          ToastCenter.shared.showSuccess("No older messages to load")
        }
      } catch is CancellationError {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showSuccess("History loading canceled")
      } catch {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showError("Failed to load chat history")
      }
    }
  }

  @MainActor
  private func cancelHistoryLoad() {
    loadHistoryTask?.cancel()
  }

  @MainActor
  private func fetchHistoryInBatches(targetCount: Int, batchSize: Int32) async throws -> Int {
    var loadedCount = 0
    var offsetID: Int64?
    var previousOldestMessageID: Int64?

    while loadedCount < targetCount {
      try Task.checkCancellation()

      let remaining = targetCount - loadedCount
      let requestedLimit = Int32(min(Int(batchSize), remaining))
      guard requestedLimit > 0 else { break }

      let rpcResult = try await realtimeV2.send(
        .getChatHistory(peer: peer, offsetID: offsetID, limit: requestedLimit)
      )
      try Task.checkCancellation()

      guard let rpcResult, case let .getChatHistory(result) = rpcResult else {
        throw ChatToolbarMenuError.invalidHistoryResponse
      }

      let batchMessages = result.messages
      guard batchMessages.isEmpty == false else { break }

      loadedCount += batchMessages.count

      ToastCenter.shared.showLoading(
        loadingHistoryMessage(loaded: min(loadedCount, targetCount), target: targetCount),
        actionTitle: "Cancel",
        action: { cancelHistoryLoad() }
      )

      guard let oldestMessageID = batchMessages.last?.id else { break }
      if let previousOldestMessageID, oldestMessageID >= previousOldestMessageID {
        break
      }

      previousOldestMessageID = oldestMessageID
      offsetID = oldestMessageID

      if batchMessages.count < Int(requestedLimit) {
        break
      }
    }

    return min(loadedCount, targetCount)
  }

  private func loadingHistoryMessage(loaded: Int, target: Int) -> String {
    "Loading chat history... \(loaded)/\(target)"
  }

  private func moveThreadToHome() {
    guard let chatId = peer.asThreadId() else { return }
    showMoveOutConfirm = false

    Task(priority: .userInitiated) {
      await MainActor.run {
        ToastCenter.shared.showLoading("Moving thread...")
      }

      do {
        _ = try await realtimeV2.send(.moveThread(chatID: chatId, spaceID: nil))
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showSuccess("Moved to Home")
        }

        await MainActor.run {
          dependencies.requestOpenChatInHome(peer: peer)
        }
      } catch {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("Failed to move thread")
        }
      }
    }
  }

  @MainActor
  private func performDestructiveAction(_ action: ChatDestructiveAction) {
    pendingDestructiveAction = nil
    ChatDestructiveActionRunner.perform(action, peer: peer, dependencies: dependencies) {
      dependencies.nav2?.navigate(to: .empty)
      dependencies.nav3?.open(.empty)
      dependencies.nav.open(.empty)
    }
  }
}

@MainActor
private final class ChatToolbarMenuModel: ObservableObject {
  @Published private(set) var state = ChatToolbarMenuState()

  private let peer: Peer
  private let db: AppDatabase
  private var stateCancellable: AnyCancellable?

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    bindState()
  }

  deinit {
    stateCancellable?.cancel()
  }

  private func bindState() {
    let peer = peer
    let currentUserId = Auth.shared.getCurrentUserId()

    db.warnIfInMemoryDatabaseForObservation("ChatToolbarMenuModel.state")
    stateCancellable = ValueObservation
      .tracking { db in
        let dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer))
        let chat = try peer.asThreadId().map { try Chat.fetchOne(db, id: $0) } ?? nil

        return try ChatToolbarMenuState(
          dialog: dialog,
          chat: chat,
          peer: peer,
          currentUserId: currentUserId,
          db: db
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] state in
          guard self?.state != state else { return }
          self?.state = state
        }
      )
  }
}

private struct ChatToolbarMenuState: Equatable {
  var isPinned = false
  var isArchived = false
  var isSidebarVisible = true
  var canRename = false
  var chatSpaceId: Int64?
  var title = "Chat"
  var destructiveAction: ChatDestructiveAction?

  init() {}

  init(
    dialog: Dialog?,
    chat: Chat?,
    peer: Peer,
    currentUserId: Int64?,
    db: Database
  ) throws {
    isPinned = dialog?.pinned ?? false
    isArchived = dialog?.archived ?? false
    isSidebarVisible = dialog?.sidebarVisible != false
    chatSpaceId = chat?.spaceId
    title = chat?.humanReadableTitle ?? "Chat"
    destructiveAction = ChatDestructiveActionResolver.action(
      peer: peer,
      chat: chat,
      currentUserId: currentUserId
    )
    canRename = try Self.resolveCanRename(
      chat: chat,
      peer: peer,
      currentUserId: currentUserId,
      db: db
    )
  }

  private static func resolveCanRename(
    chat _: Chat?,
    peer: Peer,
    currentUserId: Int64?,
    db: Database
  ) throws -> Bool {
    try ChatRenamePermission.canRename(peer: peer, currentUserId: currentUserId, db: db)
  }
}

private enum ChatToolbarMenuError: Error {
  case invalidHistoryResponse
}
