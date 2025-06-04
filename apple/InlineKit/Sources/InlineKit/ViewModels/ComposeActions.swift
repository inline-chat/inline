import Auth
import Combine
import Logger
import SwiftUI

public struct ComposeActionInfo {
  public var userId: Int64
  public var action: ApiComposeAction
  var expiresAt: Date
}

@MainActor
public class ComposeActions: ObservableObject {
  public static let shared = ComposeActions()

  // New structure: [Peer: [UserId: ComposeActionInfo]]
  @Published public var actions: [Peer: [Int64: ComposeActionInfo]] = [:]
  private var _activeUploads: Set<Peer> = []

  private var cancelTasks: [Peer: [Int64: Task<Void, Never>]] = [:]
  private var log = Log.scoped("ComposeActions", enableTracing: false)
  private var lastTypingSent: [Peer: Date] = [:]

  public init() {}

  // MARK: - New Group-Aware Methods

  /// Get all compose actions for a peer
  public func getComposeActions(for peer: Peer) -> [Int64: ComposeActionInfo] {
    actions[peer] ?? [:]
  }

  /// Get active typing users for a peer
  public func getTypingUsers(for peer: Peer) -> [Int64] {
    let currentActions = getComposeActions(for: peer)
    return currentActions.compactMap { userId, actionInfo in
      actionInfo.action == .typing ? userId : nil
    }
  }

  /// Add compose action for a specific user in a peer
  public func addComposeAction(for peer: Peer, action: ApiComposeAction, userId: Int64) {
    log.trace("action \(action) added for user \(userId) in \(peer)")

    // Cancel existing task for this user in this peer
    cancelTasks[peer]?[userId]?.cancel()
    if cancelTasks[peer] == nil {
      cancelTasks[peer] = [:]
    }

    // Initialize actions for peer if needed
    if actions[peer] == nil {
      actions[peer] = [:]
    }

    actions[peer]![userId] = ComposeActionInfo(userId: userId, action: action, expiresAt: Date().addingTimeInterval(6))

    // Expire after 6s if not updated
    cancelTasks[peer]![userId] = Task {
      self.log.trace("typing action expired for user \(userId) in \(peer)")
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.removeComposeAction(for: peer, userId: userId)
      }
    }
  }

  /// Remove compose action for a specific user in a peer
  public func removeComposeAction(for peer: Peer, userId: Int64) {
    log.trace("removed action for user \(userId) in \(peer)")
    actions[peer]?[userId] = nil

    // Clean up empty peer entries
    if actions[peer]?.isEmpty == true {
      actions[peer] = nil
    }

    cancelTasks[peer]?[userId]?.cancel()
    cancelTasks[peer]?[userId] = nil

    // Clean up empty peer entries in cancel tasks
    if cancelTasks[peer]?.isEmpty == true {
      cancelTasks[peer] = nil
    }
  }

  /// Remove all compose actions for a peer
  public func removeAllComposeActions(for peer: Peer) {
    log.trace("removed all actions for \(peer)")

    // Cancel all tasks for this peer
    cancelTasks[peer]?.values.forEach { $0.cancel() }
    cancelTasks[peer] = nil

    // Remove all actions for this peer
    actions[peer] = nil
  }

  // MARK: - Backwards Compatibility Methods

  /// Get the first compose action for a peer (backwards compatibility)
  public func getComposeAction(for peer: Peer) -> ComposeActionInfo? {
    actions[peer]?.values.first
  }

  /// Remove compose action for peer (backwards compatibility - removes all)
  public func removeComposeAction(for peer: Peer) {
    removeAllComposeActions(for: peer)
  }

  // MARK: - Sending Methods

  // Sending side
  private func sendComposeAction(for peerId: Peer, action: ApiComposeAction?) async throws {
    let _ = try await InlineKit.Realtime.shared.invoke(.sendComposeAction, input: .sendComposeAction(.with {
      $0.peerID = peerId.toInputPeer()
      $0.action = action?.toProtocolComposeAction() ?? .none
    }))
  }

  public func startedTyping(for peerId: Peer) async {
    // Don't clear an active upload with typing
    if _activeUploads.contains(peerId) {
      return
    }

    if let lastSent = lastTypingSent[peerId], lastSent.timeIntervalSinceNow > -3 {
      // Previous one still valid since it hasn't been 6s
      return
    }

    // Send typing action immediately
    do {
      lastTypingSent[peerId] = Date()
      log.trace("sending typing status for \(peerId)")
      try await sendComposeAction(for: peerId, action: .typing)
    } catch {
      log.error("Failed to send typing status: \(error)")
    }
  }

  public func stoppedTyping(for peerId: Peer) async {
    // Don't clear an active upload with stop typing
    if _activeUploads.contains(peerId) {
      return
    }

    lastTypingSent[peerId] = nil

    // Send stop typing action immediately
    do {
      try await sendComposeAction(for: peerId, action: nil)
    } catch {
      log.error("Failed to send stop typing status: \(error)")
    }
  }
}

// MARK: - Upload Actions Extension

public extension ComposeActions {
  /// Manages upload compose actions (photo, document, video) for a peer during file upload
  /// - Parameters:
  ///   - peerId: The peer to send the compose action to
  ///   - action: The upload action type (.uploadingPhoto, .uploadingDocument, or .uploadingVideo)
  /// - Returns: A function to call when upload is complete
  func startUpload(for peerId: Peer, action: ApiComposeAction) -> @Sendable () -> Void {
    // Validate that this is an upload action
    guard action == .uploadingPhoto || action == .uploadingDocument || action == .uploadingVideo else {
      log.error("Invalid upload action: \(action). Must be one of the uploading types.")
      return {}
    }

    // Mark this peer as having an active upload
    _activeUploads.insert(peerId)
    lastTypingSent[peerId] = Date()

    // Send initial status immediately
    Task.detached(priority: .userInitiated) {
      try await self.sendComposeAction(for: peerId, action: action)
    }

    // Create a repeating task that sends the uploading status every 3 seconds
    let uploadTask = Task.detached(priority: .userInitiated) {
      do {
        // Keep sending status updates every 3 seconds until cancelled
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(3))
          if !Task.isCancelled {
            try await self.sendComposeAction(for: peerId, action: action)
            await MainActor.run {
              self.lastTypingSent[peerId] = Date()
            }
          } else {
            break
          }
        }
      } catch {
        await self.log.error("Failed to send \(action) status: \(error)")
      }
    }

    // Store the task with the peer (use current user ID for upload tasks)
    let currentUserId = Auth.shared.getCurrentUserId() ?? 0
    if cancelTasks[peerId] == nil {
      cancelTasks[peerId] = [:]
    }
    cancelTasks[peerId]![currentUserId] = uploadTask

    // Return a completion function
    return {
      Task { @MainActor in
        // Cancel the task first
        self.cancelTasks[peerId]?[currentUserId]?.cancel()
        self.cancelTasks[peerId]?[currentUserId] = nil

        // Remove from active uploads
        self._activeUploads.remove(peerId)

        // Send the "stopped uploading" status
        Task.detached(priority: .userInitiated) {
          do {
            try await self.sendComposeAction(for: peerId, action: nil)
          } catch {
            await self.log.error("Failed to send stop \(action) status: \(error)")
          }
        }
        self.lastTypingSent[peerId] = nil
      }
    }
  }

  // Convenience methods for specific upload types

  /// Starts a photo upload compose action
  func startPhotoUpload(for peerId: Peer) -> @Sendable () -> Void {
    startUpload(for: peerId, action: .uploadingPhoto)
  }

  /// Starts a document upload compose action
  func startDocumentUpload(for peerId: Peer) -> @Sendable () -> Void {
    startUpload(for: peerId, action: .uploadingDocument)
  }

  /// Starts a video upload compose action
  func startVideoUpload(for peerId: Peer) -> @Sendable () -> Void {
    startUpload(for: peerId, action: .uploadingVideo)
  }
}

// MARK: - User Name Helper

public extension ComposeActions {
  /// Get display names for typing users asynchronously
  func getTypingUsersDisplayNames(for peer: Peer) async -> [String] {
    let typingUserIds = getTypingUsers(for: peer)

    return await withTaskGroup(of: (Int64, String?).self) { group in
      for userId in typingUserIds {
        group.addTask {
          // Fetch user info in background
          let userInfo = await MainActor.run {
            ObjectCache.shared.getUser(id: userId)
          }
          return (userId, userInfo?.user.displayName)
        }
      }

      var results: [(Int64, String?)] = []
      for await result in group {
        results.append(result)
      }

      // Sort by original order and filter out nil names
      return typingUserIds.compactMap { userId in
        results.first { $0.0 == userId }?.1
      }
    }
  }

  /// Get formatted typing text for display
  func getTypingDisplayText(for peer: Peer, length: TypingDisplayLength = .full) async -> String? {
    let displayNames = await getTypingUsersDisplayNames(for: peer)

    // For DMs (user peers), use simpler copy since there's only one other user
    if peer.isPrivate {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          if length == .min {
            return "typing"
          } else {
            return "typing..."
          }
        default:
          // This shouldn't happen in a DM, but fallback to regular behavior
          if length == .min {
            return "typing"
          } else {
            return "typing..."
          }
      }
    }

    // For threads (group chats), show names as before
    if length == .full {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          return "\(displayNames[0]) is typing..."
        case 2:
          return "\(displayNames[0]) and \(displayNames[1]) are typing..."
        case 3:
          return "\(displayNames[0]), \(displayNames[1]) and \(displayNames[2]) are typing..."
        default:
          return "\(displayNames[0]), \(displayNames[1]) and \(displayNames.count - 2) others are typing..."
      }
    } else if length == .short {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          return "\(displayNames[0]) is typing..."
        case 2:
          return "\(displayNames[0]) and \(displayNames[1]) are typing..."
        default:
          return "\(displayNames[0]) and \(displayNames.count - 1) others are typing..."
      }
    } else {
      switch displayNames.count {
        case 0:
          return nil
        case 1:
          return "\(displayNames[0])"
        case 2:
          return "\(displayNames[0]) and \(displayNames[1])"
        default:
          return "\(displayNames[0]) and \(displayNames.count - 1) others"
      }
    }
  }

  /// Display length options for typing text
  enum TypingDisplayLength {
    case full // "User is typing..."
    case short // "User is typing..."
    case min // "User"
  }
}
