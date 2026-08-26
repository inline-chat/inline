import InlineKit
import InlineSearch
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct InlineSearchResultsList: View {
  let model: InlineSearchViewModel
  let openChat: (InlineSearchChatResult) -> Void
  let openMessage: (LocalMessageSearchResult) -> Void
  let openGlobalUser: (InlineSearchGlobalUserResult) -> Void

  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var themeManager: ThemeManager
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var appDatabase
  @Environment(\.realtimeV2) private var realtimeV2

  var body: some View {
    List {
      if model.chats.isEmpty == false {
        InlineSearchSectionHeader(title: "Chats")

        ForEach(model.chats) { result in
          searchChatRow(for: result)
            // Match the polished Home rows: spacing belongs inside the
            // interactive source so hold highlighting lifts the whole cell.
            .listRowInsets(EdgeInsets())
        }
      }

      if model.messages.isEmpty == false {
        InlineSearchSectionHeader(title: "Messages")

        ForEach(model.messages) { result in
          InlineSearchMessageRow(result: result) {
            openMessage(result)
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            addToInboxButton(peer: result.peer)
          }
          .onAppear {
            if result.id == model.messages.last?.id {
              model.loadMoreMessages()
            }
          }
        }

        if model.isLoadingMoreMessages {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
        }
      }

      if model.globalUsers.isEmpty == false {
        InlineSearchSectionHeader(title: "People")

        ForEach(model.globalUsers) { result in
          InlineSearchGlobalUserRow(result: result) {
            openGlobalUser(result)
          }
        }
      }
    }
    .listStyle(.plain)
    .contentMargins(.bottom, 32, for: .scrollContent)
  }

  @ViewBuilder
  private func searchChatRow(for result: InlineSearchChatResult) -> some View {
    let row = InlineSearchChatRow(result: result) {
      openChat(result)
    }
    .contentShape(.interaction, Rectangle())
    .contentShape(.contextMenuPreview, Capsule())
    .contextMenu {
      chatContextMenuActions(for: result)
    } preview: {
      chatPreview(for: result)
    }
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      if result.peer.asUserId() == nil {
        followSwipeButton(for: result)
      }
    }

    row.swipeActions(edge: .trailing, allowsFullSwipe: true) {
      openSwipeButton(for: result)
      pinSwipeButton(for: result)
    }
  }

  @ViewBuilder
  private func chatContextMenuActions(for result: InlineSearchChatResult) -> some View {
    Button {
      openInInbox(result)
    } label: {
      Label("Open", systemImage: "tray.and.arrow.down")
      Text("Add to Open Chats")
    }

    Button {
      updatePin(for: result)
    } label: {
      Label(
        result.pinned ? "Unpin" : "Pin",
        systemImage: result.pinned ? "pin.slash" : "pin"
      )
    }

    if result.peer.asUserId() == nil {
      Button {
        updateFollow(for: result)
      } label: {
        Label(
          isFollowed(result) ? "Unfollow" : "Follow",
          systemImage: isFollowed(result) ? "eye.slash" : "eye"
        )
      }
    }
  }

  private func pinSwipeButton(for result: InlineSearchChatResult) -> some View {
    Button {
      updatePin(for: result)
    } label: {
      Label(
        result.pinned ? "Unpin" : "Pin",
        systemImage: result.pinned ? "pin.slash.fill" : "pin.fill"
      )
    }
    .tint(.indigo)
  }

  private func openSwipeButton(for result: InlineSearchChatResult) -> some View {
    Button {
      openInInbox(result)
    } label: {
      Label("Open", systemImage: "tray.and.arrow.down.fill")
    }
    .tint(.green)
  }

  private func followSwipeButton(for result: InlineSearchChatResult) -> some View {
    Button {
      updateFollow(for: result)
    } label: {
      Label(
        isFollowed(result) ? "Unfollow" : "Follow",
        systemImage: isFollowed(result) ? "eye.slash.fill" : "eye.fill"
      )
    }
    .tint(.purple)
  }

  private func chatPreview(for result: InlineSearchChatResult) -> some View {
    ChatContextMenuPreview(
      peer: result.peer,
      contextSpaceID: result.spaceId,
      router: router,
      data: dataManager,
      themeManager: themeManager,
      notificationSettings: notificationSettings,
      realtimeState: realtimeState,
      realtimeV2: realtimeV2,
      appDatabase: appDatabase
    )
  }

  private func isOpen(_ result: InlineSearchChatResult) -> Bool {
    result.snapshot.item.dialog.open == true && result.archived == false
  }

  private func isFollowed(_ result: InlineSearchChatResult) -> Bool {
    result.snapshot.item.dialog.followMode == .following
  }

  private func addToInboxButton(peer: Peer) -> some View {
    Button {
      openInInbox(peer: peer)
    } label: {
      Label("Open", systemImage: "tray.and.arrow.down.fill")
    }
    .tint(.green)
  }

  private func openInInbox(_ result: InlineSearchChatResult) {
    if isOpen(result) {
      ToastManager.shared.showToast(
        "Already open",
        description: "This chat is already in Open Chats.",
        type: .info,
        systemImage: "bubble.left.fill"
      )
      return
    }
    openInInbox(peer: result.peer)
  }

  private func openInInbox(peer: Peer) {
    Task(priority: .userInitiated) {
      do {
        let didPerform = try await InboxMembershipService.shared.open(peer: peer)
        guard didPerform else { return }
        model.refresh()
        ToastManager.shared.showToast(
          "Now in Open Chats",
          type: .success,
          systemImage: "bubble.left.fill"
        )
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to add Search result to Inbox", error: error)
        ToastManager.shared.showToast(
          "Couldn’t open chat",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func updatePin(for result: InlineSearchChatResult) {
    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.updateDialogOrder(
          peerId: result.peer,
          pinned: !result.pinned
        ))
        model.refresh()
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update Search result pin state", error: error)
        ToastManager.shared.showToast(
          "Could not update pin",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }

  private func updateFollow(for result: InlineSearchChatResult) {
    let wasFollowed = isFollowed(result)
    Task(priority: .userInitiated) {
      do {
        _ = try await realtimeV2.send(.updateDialogFollowMode(
          peerId: result.peer,
          selection: wasFollowed ? .unfollowed : .following
        ))
        model.refresh()
        ToastManager.shared.showToast(
          wasFollowed ? "Unfollowed" : "Following",
          description: wasFollowed
            ? "Only mentions and replies can bring this chat back."
            : "New messages will appear in Open Chats.",
          type: .success,
          systemImage: wasFollowed ? "eye.slash.fill" : "eye.fill"
        )
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to update Search result follow state", error: error)
        ToastManager.shared.showToast(
          "Could not update follow state",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }
}

private struct InlineSearchSectionHeader: View {
  let title: LocalizedStringKey

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
      .listRowInsets(.init(
        top: 12,
        leading: Theme.Layout.screenEdgeOpticalInset,
        bottom: 4,
        trailing: Theme.Layout.screenEdgeOpticalInset
      ))
      .listRowSeparator(.hidden)
  }
}

private struct InlineSearchChatRow: View {
  let result: InlineSearchChatResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        subtitle: nil,
        icon: {
          chatIcon
        }
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.init(
        top: 4,
        leading: Theme.Layout.screenEdgeOpticalInset,
        bottom: 4,
        trailing: Theme.Layout.screenEdgeOpticalInset
      ))
      .contentShape(.interaction, Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.interaction, Rectangle())
  }

  @ViewBuilder
  private var chatIcon: some View {
    if let userInfo = result.userInfo {
      UserAvatar(userInfo: userInfo, size: 34)
    } else {
      ThreadIconView(
        threadIconDescriptor(
          chat: result.chat,
          title: result.title
        ),
        size: .regular(34),
        shape: .circle
      )
    }
  }
}

private struct InlineSearchMessageRow: View {
  let result: LocalMessageSearchResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        subtitle: result.snippet,
        detail: dateTitle,
        icon: {
          messageIcon
        }
      )
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(
      top: 4,
      leading: Theme.Layout.screenEdgeOpticalInset,
      bottom: 4,
      trailing: Theme.Layout.screenEdgeOpticalInset
    ))
  }

  @ViewBuilder
  private var messageIcon: some View {
    if let user = result.peerUser {
      UserAvatar(user: user, size: 34)
    } else {
      ThreadIconView(
        threadIconDescriptor(
          chat: result.chat,
          title: result.title
        ),
        size: .regular(34),
        shape: .circle
      )
    }
  }

  private var dateTitle: String {
    result.message.message.date.formatted(date: .abbreviated, time: .omitted)
  }
}

private func threadIconDescriptor(chat: Chat?, title: String) -> ThreadIconDescriptor {
  if let chat {
    return ThreadIconDescriptor(chat: chat)
  }

  return ThreadIconDescriptor(
    emoji: nil,
    title: title,
    accessibilityLabel: title
  )
}

private struct InlineSearchGlobalUserRow: View {
  let result: InlineSearchGlobalUserResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        subtitle: result.subtitle,
        icon: {
          UserAvatar(apiUser: result.user, size: 34)
        }
      )
    }
    .buttonStyle(.plain)
    .listRowInsets(.init(
      top: 4,
      leading: Theme.Layout.screenEdgeOpticalInset,
      bottom: 4,
      trailing: Theme.Layout.screenEdgeOpticalInset
    ))
  }
}

private struct InlineSearchResultRow<Icon: View>: View {
  let title: String
  let subtitle: String?
  var detail: String?
  @ViewBuilder let icon: () -> Icon

  init(
    title: String,
    subtitle: String?,
    detail: String? = nil,
    @ViewBuilder icon: @escaping () -> Icon
  ) {
    self.title = title
    self.subtitle = subtitle
    self.detail = detail
    self.icon = icon
  }

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      icon()
        .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(title)
            .font(.body)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

          if let detail {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        if let subtitle, subtitle.isEmpty == false {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .contentShape(Rectangle())
  }
}
