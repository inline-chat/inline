import Auth
import Combine
import GRDB
import InlineKit
import SwiftUI

struct ChatToolbarMenuButton: View {
  let peer: Peer
  let dependencies: AppDependencies

  @Environment(\.realtimeV2) private var realtimeV2

  @ObservedObject private var settings = AppSettings.shared
  @StateObject private var model: ChatToolbarMenuModel
  @State private var showRenameSheet = false
  @State private var showMoveToSpaceSheet = false
  @State private var showMoveOutConfirm = false
  @State private var showClearHistorySheet = false
  @State private var pendingDestructiveAction: ChatDestructiveAction?
  @State private var loadHistoryTask: Task<Void, Never>?

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    _model = StateObject(wrappedValue: ChatToolbarMenuModel(peer: peer, db: dependencies.database))
  }

  var body: some View {
    Menu {
      Button("Chat Info", systemImage: "info.circle") {
        openChatInfo()
      }

      Divider()

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

      if peer.isThread, model.state.isChatListHidden {
        Button("Keep in Chat List", systemImage: "sidebar.left") {
          keepInChatList()
        }
      }

      if settings.sidebarAsInbox,
         !(model.state.isOpen && model.state.isArchived == false && model.state.isChatListHidden == false) {
        Button("Open in Sidebar", systemImage: "sidebar.left") {
          openInSidebar()
        }
      }

      if loadHistoryTask == nil {
        Button("Load chat history", systemImage: "arrow.down.circle") {
          loadLast1000Messages()
        }
      }

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

      if model.state.canClearHistory || model.state.destructiveAction != nil {
        Divider()

        if model.state.canClearHistory {
          Button(role: .destructive) {
            showClearHistorySheet = true
          } label: {
            Label("Clear History...", systemImage: "trash")
          }
        }

        if let destructiveAction = model.state.destructiveAction {
          Button(destructiveAction.title, systemImage: destructiveAction.systemImage, role: .destructive) {
            pendingDestructiveAction = destructiveAction
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("More")
    .help("More")
    .sheet(isPresented: $showRenameSheet) {
      RenameChatSheet(peer: peer)
    }
    .sheet(isPresented: $showMoveToSpaceSheet) {
      if let chatId = peer.asThreadId() {
        MoveThreadToSpaceSheet(chatId: chatId, nav2: dependencies.nav2, nav3: dependencies.nav3)
      }
    }
    .sheet(isPresented: $showClearHistorySheet) {
      ClearChatHistorySheet(
        peer: peer,
        chatTitle: model.state.title,
        spaceId: model.state.canClearSpaceHistory ? model.state.chatSpaceId : nil
      )
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

  private func keepInChatList() {
    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.showInChatList(peerId: peer))
      } catch {
        await MainActor.run {
          ToastCenter.shared.showError("Failed to keep chat in chat list")
        }
      }
    }
  }

  private func openInSidebar() {
    Task(priority: .userInitiated) {
      do {
        if peer.isThread, model.state.isChatListHidden {
          _ = try await realtimeV2.send(.showInChatList(peerId: peer))
        }
        _ = try await realtimeV2.send(.updateDialogOpen(peerId: peer, open: true))
      } catch {
        await MainActor.run {
          ToastCenter.shared.showError("Failed to open chat in sidebar")
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
  var isChatListHidden = false
  var isOpen = false
  var canRename = false
  var canClearHistory = false
  var canClearSpaceHistory = false
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
    isChatListHidden = dialog?.chatListHidden == true
    isOpen = dialog?.open == true
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
    canClearHistory = try Self.resolveCanClearHistory(
      chat: chat,
      peer: peer,
      currentUserId: currentUserId,
      db: db
    )
    canClearSpaceHistory = try Self.resolveCanClearSpaceHistory(
      chat: chat,
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

  private static func resolveCanClearHistory(
    chat: Chat?,
    peer: Peer,
    currentUserId: Int64?,
    db: Database
  ) throws -> Bool {
    guard let currentUserId else { return false }

    if peer.isPrivate {
      return true
    }

    guard peer.isThread, let chat, chat.type == .thread else {
      return false
    }

    if chat.createdBy == currentUserId {
      return true
    }

    guard let spaceId = chat.spaceId else {
      return false
    }

    let member = try Member
      .filter(Member.Columns.spaceId == spaceId)
      .filter(Member.Columns.userId == currentUserId)
      .fetchOne(db)

    return member?.role == .admin || member?.role == .owner
  }

  private static func resolveCanClearSpaceHistory(
    chat: Chat?,
    currentUserId: Int64?,
    db: Database
  ) throws -> Bool {
    guard let currentUserId, let spaceId = chat?.spaceId else { return false }

    let member = try Member
      .filter(Member.Columns.spaceId == spaceId)
      .filter(Member.Columns.userId == currentUserId)
      .fetchOne(db)

    return member?.role == .admin || member?.role == .owner
  }
}

private enum ChatToolbarMenuError: Error {
  case invalidHistoryResponse
}

private struct ClearChatHistorySheet: View {
  let peer: Peer
  let chatTitle: String
  let spaceId: Int64?

  @Environment(\.dismiss) private var dismiss
  @State private var range: ClearChatHistoryRange = .keep(90)
  @State private var customDays = 90
  @State private var deleteReplyThreads = false
  @State private var clearSpace = false
  @State private var isSubmitting = false
  @State private var showClearConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Clear History for Everyone")
          .font(.headline)
        Text(chatTitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Picker("Range", selection: $range) {
        ForEach(ClearChatHistoryRange.allCases) { range in
          Text(range.title).tag(range)
        }
      }
      .pickerStyle(.radioGroup)

      if range == .custom {
        Stepper("Keep last \(customDays) days", value: $customDays, in: 1 ... 36_500)
      }

      Toggle("Delete reply threads", isOn: $deleteReplyThreads)

      if spaceId != nil {
        Toggle("Clear all chats in this space", isOn: $clearSpace)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)

        Button("Clear", role: .destructive) {
          showClearConfirmation = true
        }
        .disabled(isSubmitting)
      }
    }
    .padding(20)
    .frame(width: 360)
    .alert("Clear history for everyone?", isPresented: $showClearConfirmation) {
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)

      Button("Clear History", role: .destructive) {
        clearHistory()
      }
    } message: {
      Text(clearConfirmationMessage)
    }
  }

  private var keepLastDays: Int32 {
    switch range {
    case .all:
      0
    case let .keep(days):
      Int32(days)
    case .custom:
      Int32(customDays)
    }
  }

  private var clearConfirmationMessage: String {
    let target = clearSpace && spaceId != nil ? "all chats in this space" : "this chat"
    let rangeText = keepLastDays == 0 ? "all history" : "history older than \(keepLastDays) days"
    return "This will clear \(rangeText) from \(target) for everyone. You will have 5 seconds to undo before it starts."
  }

  @MainActor
  private func clearHistory() {
    guard !isSubmitting else { return }
    let selectedKeepLastDays = keepLastDays
    let shouldDeleteReplyThreads = deleteReplyThreads
    let selectedSpaceId = clearSpace ? spaceId : nil
    isSubmitting = true

    DelayedDestructiveActionScheduler.shared.cancelAll()
    let token = DelayedDestructiveActionScheduler.shared.schedule(
      onPerforming: {
        ToastCenter.shared.showLoading("Clearing history...")
      },
      action: {
        if let selectedSpaceId {
          _ = try await Api.realtime.send(.clearChatHistory(
            spaceId: selectedSpaceId,
            keepLastDays: selectedKeepLastDays,
            deleteReplyThreads: shouldDeleteReplyThreads
          ))
        } else {
          _ = try await Api.realtime.send(.clearChatHistory(
            peerId: peer,
            keepLastDays: selectedKeepLastDays,
            deleteReplyThreads: shouldDeleteReplyThreads
          ))
        }
      },
      onSuccess: {
        ToastCenter.shared.showSuccess("History cleared")
      },
      onFailure: { _ in
        ToastCenter.shared.showError("Failed to clear history")
      }
    )

    ToastCenter.shared.showUndoCountdown("Clearing history") {
      if DelayedDestructiveActionScheduler.shared.cancel(token) {
        ToastCenter.shared.showSuccess("Clear history canceled")
      }
    }
    dismiss()
  }
}

private enum ClearChatHistoryRange: Hashable, Identifiable, CaseIterable {
  case all
  case keep(Int)
  case custom

  static let allCases: [ClearChatHistoryRange] = [
    .keep(90),
    .keep(7),
    .keep(30),
    .all,
    .custom,
  ]

  var id: String {
    switch self {
    case .all:
      "all"
    case let .keep(days):
      "keep-\(days)"
    case .custom:
      "custom"
    }
  }

  var title: String {
    switch self {
    case .all:
      "All history"
    case let .keep(days):
      "Keep last \(days) days"
    case .custom:
      "Custom"
    }
  }
}
