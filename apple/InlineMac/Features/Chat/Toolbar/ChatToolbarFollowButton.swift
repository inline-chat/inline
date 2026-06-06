import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI

struct ChatToolbarFollowButton: View {
  let peer: Peer
  let db: AppDatabase

  @StateObject private var model: ChatToolbarFollowModel

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    _model = StateObject(wrappedValue: ChatToolbarFollowModel(peer: peer, db: db))
  }

  var body: some View {
    if model.state.isReplyThread {
      Button {
        model.toggle()
      } label: {
        Label(model.state.title, systemImage: model.state.systemImage)
          .labelStyle(.iconOnly)
      }
      .accessibilityLabel(model.state.title)
      .accessibilityHint(model.state.tooltip)
      .help(model.state.tooltip)
    }
  }
}

@MainActor
private final class ChatToolbarFollowModel: ObservableObject {
  @Published private(set) var state = ChatToolbarFollowState()

  private let peer: Peer
  private let db: AppDatabase
  private var cancellable: AnyCancellable?

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    bindState()
  }

  deinit {
    cancellable?.cancel()
  }

  func toggle() {
    guard state.isReplyThread else { return }

    let previousState = state
    let selection: DialogFollowModeSelection = state.isFollowing ? .relevance : .following
    state.isFollowing.toggle()

    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogFollowMode(peerId: peer, selection: selection))
        await MainActor.run {
          ToastCenter.shared.showSuccess(Self.successMessage(for: selection))
        }
      } catch {
        Log.shared.error("Failed to update dialog follow mode", error: error)
        await MainActor.run {
          self.state = previousState
          ToastCenter.shared.showError("Failed to update follow mode")
        }
      }
    }
  }

  private static func successMessage(for selection: DialogFollowModeSelection) -> String {
    switch selection {
      case .following:
        "Thread followed. New replies will appear in the sidebar."
      case .relevance:
        "Thread unfollowed. Only mentions will bring it back."
    }
  }

  private func bindState() {
    let peer = peer

    db.warnIfInMemoryDatabaseForObservation("ChatToolbarFollowModel.state")
    cancellable = ValueObservation
      .tracking { db in
        let dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer))
        let chat = try peer.asThreadId().map { try Chat.fetchOne(db, id: $0) } ?? nil

        return ChatToolbarFollowState(
          isReplyThread: chat?.isReplyThread == true,
          isFollowing: dialog?.isFollowingReplyThread == true
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] state in
          Task { @MainActor in
            guard self?.state != state else { return }
            self?.state = state
          }
        }
      )
  }
}

private struct ChatToolbarFollowState: Equatable {
  var isReplyThread = false
  var isFollowing = false

  var title: String {
    isFollowing ? "Unfollow Thread" : "Follow Thread"
  }

  var systemImage: String {
    isFollowing ? "checkmark" : "eye"
  }

  var tooltip: String {
    isFollowing
      ? "Stop showing all new replies in the sidebar."
      : "Show this thread in the sidebar for new replies."
  }
}
