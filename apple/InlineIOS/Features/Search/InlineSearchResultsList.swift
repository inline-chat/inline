import InlineKit
import InlineSearch
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct InlineSearchResultsList: View {
  let model: InlineSearchViewModel
  let openChat: (InlineSearchChatResult) -> Void
  let openMessage: (InlineSearchMessageResult) -> Void
  let openGlobalUser: (InlineSearchGlobalUserResult) -> Void

  @EnvironmentObject private var dataManager: DataManager
  @EnvironmentObject private var themeManager: ThemeManager
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager
  @EnvironmentObject private var realtimeState: RealtimeState
  @Environment(Router.self) private var router
  @Environment(\.appDatabase) private var appDatabase
  @Environment(\.realtimeV2) private var realtimeV2

  /// Chats past this count wait behind Show More so message hits stay on screen.
  private static let collapsedChatCount = 3

  @State private var chatNameFilter = InlineSearchChatNameFilter()
  @State private var showsAllChats = false

  var body: some View {
    let chats = visibleChats

    List {
      if chats.isEmpty == false {
        InlineSearchSectionHeader(
          title: "Chats",
          actionTitle: chatsHeaderActionTitle(chatCount: chats.count)
        ) {
          withAnimation {
            showsAllChats.toggle()
          }
        }

        ForEach(showsAllChats ? chats : Array(chats.prefix(Self.collapsedChatCount))) { result in
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
            open(result)
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

        if let note = messagesNote {
          Text(note)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
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
    .onChange(of: model.query) {
      showsAllChats = false
    }
  }

  /// Chats whose own name matches. The looser matches (space name, last
  /// message preview, a shared email domain, scattered letters) only show
  /// once search settles with no messages or people, so the screen isn't
  /// blank and they never sit above message hits.
  private var visibleChats: [InlineSearchChatResult] {
    let nameMatches = chatNameFilter.nameMatches(in: model.chats, query: model.query)
    guard nameMatches.isEmpty else { return nameMatches }
    guard model.isSearching == false, model.messages.isEmpty, model.globalUsers.isEmpty else {
      return []
    }
    return model.chats
  }

  private func chatsHeaderActionTitle(chatCount: Int) -> LocalizedStringKey? {
    guard chatCount > Self.collapsedChatCount else { return nil }
    return showsAllChats ? "Show Less" : "Show More"
  }

  private var messagesNote: String? {
    if model.cloudMessagesUnavailable {
      return "Showing messages on this device."
    }
    if model.messagesIndexIncomplete, model.hasMoreMessages == false {
      return "Older messages are still being indexed."
    }
    return nil
  }

  /// A hit can be in a chat this device never stored, such as a thread never
  /// opened. Fetch that chat first so the chat screen has it.
  private func open(_ result: InlineSearchMessageResult) {
    guard result.isChatStored == false else {
      openMessage(result)
      return
    }
    Task { @MainActor in
      do {
        _ = try await realtimeV2.send(.getChat(peer: result.peer))
      } catch {
        Log.shared.error("Search: couldn't fetch the chat of a message hit", error: error)
      }
      openMessage(result)
    }
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

/// The shared search engine also matches a chat by its space's name, its last
/// message preview, its user's email (every coworker shares the domain) and
/// letters scattered through the title. This keeps chats whose own title or
/// username matches at a word start, or as a substring once the query has
/// three characters. It caches by query and result identity so re-renders
/// while messages page in don't re-match every chat. Used from the view only.
private final class InlineSearchChatNameFilter {
  private var cachedQuery: String?
  private var cachedChats: [InlineSearchChatResult] = []
  private var cachedMatches: [InlineSearchChatResult] = []

  func nameMatches(in chats: [InlineSearchChatResult], query: String) -> [InlineSearchChatResult] {
    if query == cachedQuery, chats == cachedChats {
      return cachedMatches
    }

    let matches = Self.filter(chats, query: query)
    cachedQuery = query
    cachedChats = chats
    cachedMatches = matches
    return matches
  }

  private static func filter(_ chats: [InlineSearchChatResult], query: String) -> [InlineSearchChatResult] {
    guard chats.isEmpty == false, let prepared = InlineSearchMatcher.prepare(query) else { return [] }
    let includeEmail = query.contains("@")

    // Stable within a tier, so the engine's unread, pinned and activity order holds.
    return chats.enumerated()
      .compactMap { index, chat -> (tier: InlineSearchMatchTier, index: Int, chat: InlineSearchChatResult)? in
        guard let tier = nameMatchTier(chat, query: prepared, includeEmail: includeEmail) else { return nil }
        return (tier, index, chat)
      }
      .sorted { lhs, rhs in
        lhs.tier != rhs.tier ? lhs.tier > rhs.tier : lhs.index < rhs.index
      }
      .map(\.chat)
  }

  private static func nameMatchTier(
    _ chat: InlineSearchChatResult,
    query: InlineSearchPreparedQuery,
    includeEmail: Bool
  ) -> InlineSearchMatchTier? {
    let user = chat.userInfo?.user
    let fields = [
      InlineSearchField(chat.title, priority: 2),
      InlineSearchField(user?.username, priority: 2),
      InlineSearchField(includeEmail ? user?.email : nil, priority: 1),
    ]
    guard let match = InlineSearchMatcher.match(query: query, fields: fields) else { return nil }

    switch match.tier {
      case .exact, .fieldPrefix, .tokenPrefix:
        return match.tier
      case .substring, .compact:
        return query.compact.count >= 3 ? match.tier : nil
      case .fuzzy:
        return nil
    }
  }
}

private struct InlineSearchSectionHeader: View {
  let title: LocalizedStringKey
  var actionTitle: LocalizedStringKey?
  var action: () -> Void = {}

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)

      Spacer(minLength: 0)

      if let actionTitle {
        Button(actionTitle, action: action)
          .font(.subheadline)
          .buttonStyle(.borderless)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
  let result: InlineSearchMessageResult
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      InlineSearchResultRow(
        title: result.title,
        attributedSubtitle: result.highlightedSnippet,
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
    result.dateLabel()
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
  let subtitle: AttributedString?
  var detail: String?
  @ViewBuilder let icon: () -> Icon

  init(
    title: String,
    subtitle: String?,
    detail: String? = nil,
    @ViewBuilder icon: @escaping () -> Icon
  ) {
    self.init(title: title, attributedSubtitle: subtitle.map(AttributedString.init), detail: detail, icon: icon)
  }

  init(
    title: String,
    attributedSubtitle subtitle: AttributedString?,
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

        if let subtitle, subtitle.characters.isEmpty == false {
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
