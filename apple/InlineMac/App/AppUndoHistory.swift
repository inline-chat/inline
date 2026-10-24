import Foundation
import InlineKit
import Logger

@MainActor
final class AppUndoHistory {
  struct Intent {
    fileprivate let sequence: UInt64
    fileprivate let epoch: Int
  }

  struct ClosedChat {
    let peer: Peer
    let order: String?
    let folderID: Int64?
    let pinnedOrder: String?
    let restoresPin: Bool
  }

  struct ClosedFolder {
    var folderID: Int64
    let title: String?
    let emoji: String?
    let order: String
    let pinnedOrder: String?
    let chats: [ClosedChat]
  }

  private enum Action {
    case closeChats([ClosedChat])
    case closeFolder(ClosedFolder)
    /// `closed` holds the open and pin state archiving cleared, so undo can restore it.
    case archiveChat(peer: Peer, spaceID: Int64?, closed: ClosedChat?)

    var title: String {
      switch self {
      case let .closeChats(chats):
        chats.count == 1 ? "Close Chat" : "Close Chats"
      case .closeFolder:
        "Close Folder"
      case .archiveChat:
        "Archive Chat"
      }
    }
  }

  private struct Entry {
    let sequence: UInt64
    let action: Action
  }

  private static let limit = 50

  private var undoEntries: [Entry] = []
  private var redoEntries: [Entry] = []
  private var generation = 0
  private var epoch = 0
  private var nextSequence: UInt64 = 0
  private var transitionID: UUID?

  var canUndo: Bool {
    transitionID == nil && undoEntries.isEmpty == false
  }

  var canRedo: Bool {
    transitionID == nil && redoEntries.isEmpty == false
  }

  var undoMenuTitle: String {
    undoEntries.last.map { "Undo \($0.action.title)" } ?? "Undo"
  }

  var redoMenuTitle: String {
    redoEntries.last.map { "Redo \($0.action.title)" } ?? "Redo"
  }

  func beginIntent() -> Intent {
    nextSequence &+= 1
    return Intent(sequence: nextSequence, epoch: epoch)
  }

  @discardableResult
  func recordClosedChats(_ chats: [ClosedChat], intent: Intent) -> Bool {
    guard chats.isEmpty == false else { return false }
    return record(.closeChats(chats), intent: intent)
  }

  func recordClosedFolder(_ folder: ClosedFolder, intent: Intent) {
    record(.closeFolder(folder), intent: intent)
  }

  /// Archiving also closes and unpins the chat, so it leaves Inbox and pins entirely.
  func archiveChat(peer: Peer, spaceID: Int64?, using dependencies: AppDependencies) async throws {
    let intent = beginIntent()
    let dialog = try await dependencies.database.dbWriter.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer))
    }
    let closed = dialog.flatMap { dialog -> ClosedChat? in
      guard dialog.open == true || dialog.pinned == true else { return nil }
      return ClosedChat(
        peer: peer,
        order: dialog.order,
        folderID: dialog.folderId,
        pinnedOrder: dialog.pinnedOrder,
        restoresPin: dialog.pinned == true
      )
    }
    let action = Action.archiveChat(peer: peer, spaceID: spaceID, closed: closed)
    _ = try await execute(action, direction: .redo, using: dependencies)
    guard record(action, intent: intent) else { return }
    ToastCenter.shared.showSuccess("Chat archived", actionTitle: "Undo") { [weak self] in
      Task { await self?.undo(intent, using: dependencies) }
    }
  }

  func clear() {
    epoch &+= 1
    generation &+= 1
    transitionID = nil
    undoEntries.removeAll(keepingCapacity: true)
    redoEntries.removeAll(keepingCapacity: true)
  }

  func undo(using dependencies: AppDependencies) async {
    guard transitionID == nil, let entry = undoEntries.popLast() else { return }
    _ = await performUndo(entry, using: dependencies)
  }

  /// Undoes the action recorded for `intent`, such as from its toast, even after later actions.
  func undo(_ intent: Intent, using dependencies: AppDependencies) async {
    guard transitionID == nil,
          intent.epoch == epoch,
          let index = undoEntries.lastIndex(where: { $0.sequence == intent.sequence })
    else { return }
    let entry = undoEntries.remove(at: index)
    _ = await performUndo(entry, using: dependencies)
  }

  private func performUndo(_ entry: Entry, using dependencies: AppDependencies) async -> Bool {
    let startingGeneration = generation
    let startingEpoch = epoch
    let operationID = UUID()
    transitionID = operationID
    defer {
      if transitionID == operationID {
        transitionID = nil
      }
    }

    do {
      let completedAction = try await execute(
        entry.action,
        direction: .undo,
        using: dependencies
      )
      guard epoch == startingEpoch else { return false }
      if generation == startingGeneration {
        redoEntries.append(Entry(sequence: entry.sequence, action: completedAction))
        trim(&redoEntries)
      }
      return true
    } catch {
      guard epoch == startingEpoch else { return false }
      insertUndo(entry)
      Log.shared.error("Failed to undo \(entry.action.title)", error: error)
      ToastCenter.shared.showError("Couldn’t \(undoFailureVerb(for: entry.action))")
      return false
    }
  }

  func redo(using dependencies: AppDependencies) async {
    guard transitionID == nil, let entry = redoEntries.popLast() else { return }

    let startingGeneration = generation
    let startingEpoch = epoch
    let operationID = UUID()
    transitionID = operationID
    defer {
      if transitionID == operationID {
        transitionID = nil
      }
    }

    do {
      let completedAction = try await execute(
        entry.action,
        direction: .redo,
        using: dependencies
      )
      guard epoch == startingEpoch else { return }
      insertUndo(Entry(sequence: entry.sequence, action: completedAction))
    } catch {
      guard epoch == startingEpoch else { return }
      if generation == startingGeneration {
        redoEntries.append(entry)
        trim(&redoEntries)
      }
      Log.shared.error("Failed to redo \(entry.action.title)", error: error)
      ToastCenter.shared.showError("Couldn’t \(redoFailureVerb(for: entry.action))")
    }
  }

  @discardableResult
  private func record(_ action: Action, intent: Intent) -> Bool {
    guard intent.epoch == epoch else { return false }
    generation &+= 1
    redoEntries.removeAll(keepingCapacity: true)
    insertUndo(Entry(sequence: intent.sequence, action: action))
    return true
  }

  private func insertUndo(_ entry: Entry) {
    let insertionIndex = undoEntries.firstIndex { $0.sequence > entry.sequence }
      ?? undoEntries.endIndex
    undoEntries.insert(entry, at: insertionIndex)
    trim(&undoEntries)
  }

  private func execute(
    _ action: Action,
    direction: Direction,
    using dependencies: AppDependencies
  ) async throws -> Action {
    switch action {
    case let .closeChats(chats):
      for chat in chats {
        switch direction {
        case .undo:
          try await reopen(chat, using: dependencies)
        case .redo:
          try await close(chat, using: dependencies)
        }
      }
      return action

    case var .closeFolder(folder):
      switch direction {
      case .undo:
        let result = try await dependencies.realtimeV2.send(.createDialogFolder(
          title: folder.title,
          peers: folder.chats.map(\.peer),
          order: folder.order
        ))
        guard case let .createDialogFolder(response) = result, response.hasFolder else {
          throw ExecutionError.invalidFolderResult
        }
        folder.folderID = response.folder.id
        if folder.emoji != nil || folder.pinnedOrder != nil {
          _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
            folderId: folder.folderID,
            emoji: folder.emoji.map(UpdateDialogFolderTransaction.EmojiUpdate.set) ?? .unchanged,
            pinnedOrder: folder.pinnedOrder
              .map(UpdateDialogFolderTransaction.PinnedOrderUpdate.set) ?? .unchanged
          ))
        }
        return .closeFolder(folder)

      case .redo:
        _ = try await dependencies.realtimeV2.send(.deleteDialogFolder(
          folderId: folder.folderID,
          disposition: .closeDialogs
        ))
        return action
      }

    case let .archiveChat(peer, spaceID, closed):
      let archived: Bool
      switch direction {
      case .undo: archived = false
      case .redo: archived = true
      }
      try await DataManager.shared.updateDialog(
        peerId: peer,
        archived: archived,
        spaceId: spaceID,
        deleteEmptyThreadIfArchiving: false
      )
      if let closed {
        switch direction {
        case .undo:
          try await reopen(closed, using: dependencies)
        case .redo:
          try await close(closed, using: dependencies)
        }
      }
      return action
    }
  }

  private func reopen(_ chat: ClosedChat, using dependencies: AppDependencies) async throws {
    _ = try await dependencies.realtimeV2.send(
      .updateDialogOpen(
        peerId: chat.peer,
        open: true,
        order: chat.order,
        folderId: chat.folderID
      )
    )
    if chat.restoresPin {
      _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
        peerId: chat.peer,
        order: chat.order,
        pinnedOrder: chat.pinnedOrder,
        pinned: true
      ))
    }
  }

  private func close(_ chat: ClosedChat, using dependencies: AppDependencies) async throws {
    if chat.restoresPin {
      _ = try await dependencies.realtimeV2.send(
        .updateDialogOrder(peerId: chat.peer, pinned: false)
      )
    }
    _ = try await dependencies.realtimeV2.send(
      .updateDialogOpen(peerId: chat.peer, open: false)
    )
  }

  private func trim(_ entries: inout [Entry]) {
    guard entries.count > Self.limit else { return }
    entries.removeFirst(entries.count - Self.limit)
  }

  private func undoFailureVerb(for action: Action) -> String {
    switch action {
    case .closeChats:
      "reopen that chat"
    case .closeFolder:
      "restore that folder"
    case .archiveChat:
      "unarchive that chat"
    }
  }

  private func redoFailureVerb(for action: Action) -> String {
    switch action {
    case .closeChats:
      "close that chat again"
    case .closeFolder:
      "close that folder again"
    case .archiveChat:
      "archive that chat again"
    }
  }
}

private extension AppUndoHistory {
  enum ExecutionError: Error {
    case invalidFolderResult
  }

  enum Direction {
    case undo
    case redo
  }
}
