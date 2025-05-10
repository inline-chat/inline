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

  // for now support only one action per chat (peer)
  @Published public var actions: [Peer: ComposeActionInfo] = [:]
  private var _activeUploads: Set<Peer> = []

  private var cancelTasks: [Peer: Task<Void, Never>] = [:]
  private var log = Log.scoped("ComposeActions", enableTracing: false)
  private var lastTypingSent: [Peer: Date] = [:]

  public init() {}

  public func getComposeAction(for peer: Peer) -> ComposeActionInfo? {
    actions[peer]
  }

  public func addComposeAction(for peer: Peer, action: ApiComposeAction, userId: Int64) {
    log.trace("action added for \(peer)")
    cancelTasks[peer]?.cancel()
    cancelTasks[peer] = nil

    actions[peer] = ComposeActionInfo(userId: userId, action: action, expiresAt: Date().addingTimeInterval(6))

    // Expire after 6s if not updated
    cancelTasks[peer] = Task {
      self.log.trace("typing action expired for \(peer)")
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self.removeComposeAction(for: peer)
      }
    }
  }

  public func removeComposeAction(for peer: Peer) {
    log.trace("removed action for \(peer)")
    actions[peer] = nil
    cancelTasks[peer]?.cancel()
    cancelTasks[peer] = nil
  }

  // Sending side
  private func sendComposeAction(for peerId: Peer, action: ApiComposeAction?) async throws {
    let _ = try await ApiClient.shared.sendComposeAction(peerId: peerId, action: action)
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

    // Store the task with the peer
    cancelTasks[peerId] = uploadTask

    // Return a completion function
    return {
      Task { @MainActor in
        // Cancel the task first
        self.cancelTasks[peerId]?.cancel()
        self.cancelTasks[peerId] = nil

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
