import InlineKit
import Logger
import SwiftUI

struct ChatToolbarFollowButton: View {
  let peer: Peer
  let isFollowing: Bool

  var body: some View {
    let presentation = ChatToolbarFollowPresentation(isFollowing: isFollowing)

    Button {
      Self.toggleFollowMode(peer: peer, isFollowing: isFollowing)
    } label: {
      Label(presentation.title, systemImage: presentation.systemImage)
        .labelStyle(.iconOnly)
    }
    .accessibilityLabel(presentation.title)
    .accessibilityHint(presentation.tooltip)
    .help(presentation.tooltip)
  }

  // TODO: Move chat-level transactions like follow mode into a proper chat view model so they are centralized and easy to test.
  @MainActor
  static func toggleFollowMode(peer: Peer, isFollowing: Bool) {
    let selection: DialogFollowModeSelection = isFollowing ? .unfollowed : .following

    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogFollowMode(peerId: peer, selection: selection))
        await MainActor.run {
          ToastCenter.shared.showSuccess(Self.successMessage(for: selection))
        }
      } catch {
        Log.shared.error("Failed to update dialog follow mode", error: error)
        await MainActor.run {
          ToastCenter.shared.showError("Failed to update follow mode")
        }
      }
    }
  }

  private static func successMessage(for selection: DialogFollowModeSelection) -> String {
    switch selection {
    case .following:
      "Following thread. New messages will appear in the sidebar."
    case .unfollowed:
      "Unfollowed thread. Mentions and replies can still bring it back."
    case .relevance:
      "Using relevance mode for this thread."
    }
  }
}

struct ChatToolbarFollowPresentation: Equatable {
  var isFollowing = false

  var title: String {
    isFollowing ? "Unfollow Thread" : "Follow Thread"
  }

  var systemImage: String {
    isFollowing ? "checkmark" : "eye"
  }

  var tooltip: String {
    isFollowing
      ? "Stop adding this thread in my sidebar for every message (will be shown only for mention and replies)"
      : "Add to my sidebar on new messages"
  }
}
