import Foundation
import InlineKit
import Logger

@MainActor
final class AppUndoHistory {
  enum TargetedUndoResult {
    case completed
    case unavailable
    case failed
  }

  struct Intent {
    fileprivate let sequence: UInt64
    fileprivate let epoch: Int
  }

  struct ClosedChat {
    let peer: Peer
    let order: String?
    let pinnedOrder: String?
    let restoresNestedPin: Bool
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
    case archiveChat(peer: Peer, spaceID: Int64?)

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

  func archiveChat(peer: Peer, spaceID: Int64?) async throws {
    let intent = beginIntent()
    try await DataManager.shared.updateDialog(
      peerId: peer,
      archived: true,
      spaceId: spaceID,
      deleteEmptyThreadIfArchiving: false
    )
    record(.archiveChat(peer: peer, spaceID: spaceID), intent: intent)
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

  /// Undo a toast-owned action only while it is still the latest semantic
  /// action. This prevents an old toast from undoing unrelated newer work.
  func undo(
    _ intent: Intent,
    using dependencies: AppDependencies
  ) async -> TargetedUndoResult {
    guard transitionID == nil,
          intent.epoch == epoch,
          intent.sequence == nextSequence,
          undoEntries.last?.sequence == intent.sequence,
          let entry = undoEntries.popLast()
    else { return .unavailable }

    return await performUndo(entry, using: dependencies) ? .completed : .failed
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
          _ = try await dependencies.realtimeV2.send(
            .updateDialogOpen(peerId: chat.peer, open: true, order: chat.order)
          )
          if chat.restoresNestedPin {
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: chat.peer,
              order: chat.order,
              pinnedOrder: chat.pinnedOrder,
              pinned: true
            ))
          }
        case .redo:
          if chat.restoresNestedPin {
            _ = try await dependencies.realtimeV2.send(
              .updateDialogOrder(peerId: chat.peer, pinned: false)
            )
          }
          _ = try await dependencies.realtimeV2.send(
            .updateDialogOpen(peerId: chat.peer, open: false)
          )
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
        if folder.emoji != nil || folder.pinnedOrder != nil {
          _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
            folderId: folder.folderID,
            emoji: folder.emoji.map(UpdateDialogFolderTransaction.EmojiUpdate.set) ?? .unchanged,
            pinnedOrder: folder.pinnedOrder
              .map(UpdateDialogFolderTransaction.PinnedOrderUpdate.set) ?? .unchanged
          ))
        }
        folder.folderID = response.folder.id
        return .closeFolder(folder)

      case .redo:
        _ = try await dependencies.realtimeV2.send(.deleteDialogFolder(
          folderId: folder.folderID,
          disposition: .closeDialogs
        ))
        return action
      }

    case let .archiveChat(peer, spaceID):
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
      return action
    }
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
