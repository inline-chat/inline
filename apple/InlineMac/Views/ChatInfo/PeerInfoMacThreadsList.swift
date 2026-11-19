import InlineKit
import InlineUI
import SwiftUI

/// The Threads tab: subthreads of a thread, or threads shared with a person
/// or bot. Clicking a row opens the thread; its menu also offers the thread's
/// info.
struct PeerInfoMacThreadsList: View {
  let model: PeerInfoThreadsModel
  let emptyMessage: String
  @Environment(\.dependencies) private var dependencies

  var body: some View {
    VStack(spacing: 12) {
      if !model.items.isEmpty {
        PeerInfoCard {
          ForEach(model.items) { item in
            row(item)
              .onAppear {
                if item.id == model.items.last?.id { model.loadMore() }
              }
          }
        }
      }
      footer
    }
  }

  private func row(_ item: PeerInfoThreadsModel.Item) -> some View {
    PeerInfoActionRowButton(
      title: item.chat.humanReadableTitle ?? "Untitled",
      detail: detail(item),
      kind: .navigation,
      help: "Open this thread",
      action: { dependencies?.requestOpenChat(peer: item.peer) },
      leading: { ChatIcon(peer: .chat(item.chat), size: 28) },
      trailing: {
        if item.unreadCount > 0 {
          Text(item.unreadCount, format: .number)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
            .accessibilityLabel("\(item.unreadCount) unread")
        }
      }
    )
    .contextMenu {
      Button("Open Thread", systemImage: "bubble.left.and.bubble.right") {
        dependencies?.requestOpenChat(peer: item.peer)
      }
      Button("Show Info", systemImage: "info.circle") {
        dependencies?.openChatInfo(peer: item.peer)
      }
      Divider()
      Button("Copy Link", systemImage: "link") {
        ChatMenuActions.copyLink(for: item.peer)
      }
    }
  }

  private func detail(_ item: PeerInfoThreadsModel.Item) -> String {
    let date = item.activityDate.formatted(.relative(presentation: .named))
    guard let space = item.space?.displayName else { return date }
    return "\(space) · \(date)"
  }

  @ViewBuilder
  private var footer: some View {
    switch model.loadState {
    case .loading where model.items.isEmpty, .idle where model.items.isEmpty:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    case .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    case .failed:
      PeerInfoEmptyState(
        systemImage: "exclamationmark.triangle",
        message: "Couldn’t load threads.",
        actionTitle: "Try Again",
        action: model.retry
      )
    case .unsupported where model.items.isEmpty:
      PeerInfoEmptyState(systemImage: "bubble.left.and.bubble.right", message: "Shared threads need a newer server.")
    case .loaded where model.items.isEmpty:
      PeerInfoEmptyState(systemImage: "bubble.left.and.bubble.right", message: emptyMessage)
    default:
      EmptyView()
    }
  }
}

/// A calm empty or error state: a symbol, one line, and an optional action.
struct PeerInfoEmptyState: View {
  let systemImage: String
  let message: String
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 24, weight: .regular))
        .foregroundStyle(.tertiary)
      Text(message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }
}
