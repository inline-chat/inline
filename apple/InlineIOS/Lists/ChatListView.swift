import InlineKit
import SwiftUI
import Translation

struct ChatListView: View {
  let items: [HomeChatItem]
  let isArchived: Bool
  let onItemTap: (HomeChatItem) -> Void
  let onArchive: (HomeChatItem) -> Void
  let onPin: (HomeChatItem) -> Void
  let onRead: (HomeChatItem) -> Void
  let onUnread: (HomeChatItem) -> Void
  let showPinnedStyling: Bool
  let showPinAction: Bool

  init(
    items: [HomeChatItem],
    isArchived: Bool,
    showPinnedStyling: Bool = true,
    showPinAction: Bool = true,
    onItemTap: @escaping (HomeChatItem) -> Void,
    onArchive: @escaping (HomeChatItem) -> Void,
    onPin: @escaping (HomeChatItem) -> Void,
    onRead: @escaping (HomeChatItem) -> Void,
    onUnread: @escaping (HomeChatItem) -> Void
  ) {
    self.items = items
    self.isArchived = isArchived
    self.showPinnedStyling = showPinnedStyling
    self.onItemTap = onItemTap
    self.onArchive = onArchive
    self.onPin = onPin
    self.onRead = onRead
    self.onUnread = onUnread
    self.showPinAction = showPinAction
  }

  @Environment(Router.self) private var router
  @ObservedObject private var visibilityGate = ChatListVisibilityGate.shared
  @StateObject private var translationCoordinator = ChatListTranslationCoordinator()

  var body: some View {
    if items.isEmpty {
      EmptyChatsView(isArchived: isArchived)
    } else {
      List {
        ForEach(items, id: \.id) { item in
          chatRow(for: item)
            .listRowInsets(EdgeInsets(
              top: 8,
              leading: 16,
              bottom: 8,
              trailing: 16
            ))
        }
      }
      .listStyle(.plain)
      // Experimental: gating list animations while off-screen can change UX.
      .animation(visibilityGate.isVisible ? .default : nil, value: items)
      .onChange(of: items) { _, newItems in
        if visibilityGate.isVisible {
          translationCoordinator.process(
            items: newItems,
            currentPeers: currentPeers
          )
        }
      }
      .onAppear {
        visibilityGate.isVisible = true
        translationCoordinator.prime(items: items)
      }
      .onDisappear {
        visibilityGate.isVisible = false
        translationCoordinator.cancel()
      }
    }
  }

  @ViewBuilder
  private func chatRow(for item: HomeChatItem) -> some View {
    let isPinned = item.dialog.pinned == true

    Button {
      onItemTap(item)
    } label: {
      if let user = item.user {
        ChatListItem(
          type: .user(user, chat: item.chat),
          dialog: item.dialog,
          lastMessage: item.lastMessage?.message,
          lastMessageSender: item.lastMessage?.senderInfo,
          embeddedLastMessage: item.lastMessage,
          showsPinnedIndicator: showPinAction
        )
      } else if let chat = item.chat {
        ChatListItem(
          type: .chat(chat, spaceName: item.space?.nameWithoutEmoji),
          dialog: item.dialog,
          lastMessage: item.lastMessage?.message,
          lastMessageSender: item.lastMessage?.senderInfo,
          embeddedLastMessage: item.lastMessage,
          showsPinnedIndicator: showPinAction
        )
      } else {
        EmptyView()
      }
    }
    // .listRowBackground(rowBackground(isPinned: isPinned))
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      readUnreadButton(for: item)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      archiveButton(for: item)
      if showPinAction {
        pinButton(for: item)
      }
    }
  }

  @ViewBuilder
  private func pinButton(for item: HomeChatItem) -> some View {
    let isPinned = item.dialog.pinned ?? false

    Button {
      onPin(item)
    } label: {
      Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
    }
    .tint(.indigo)
  }

  @ViewBuilder
  private func archiveButton(for item: HomeChatItem) -> some View {
    Button(role: isArchived ? nil : .destructive) {
      onArchive(item)
    } label: {
      Label(
        isArchived ? "Unarchive" : "Archive",
        systemImage: isArchived ? "tray.and.arrow.up.fill" : "tray.and.arrow.down.fill"
      )
    }
    .tint(Color(.systemPurple))
  }

  @ViewBuilder
  private func readUnreadButton(for item: HomeChatItem) -> some View {
    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || item.dialog.unreadMark == true

    Button {
      if hasUnread {
        onRead(item)
      } else {
        onUnread(item)
      }
    } label: {
      Label(
        hasUnread ? "Mark Read" : "Mark Unread",
        systemImage: hasUnread ? "checkmark.message.fill" : "envelope.badge.fill"
      )
    }
    .tint(.blue)
  }

  private var currentPeers: Set<Peer> {
    Set(router.selectedTabPath.compactMap { destination in
      if case let .chat(peer) = destination {
        return peer
      }
      return nil
    })
  }

  private func rowBackground(isPinned: Bool) -> Color {
    guard showPinnedStyling else {
      return Color(.systemBackground)
    }
    return isPinned ? Color(.systemGray6).opacity(0.5) : Color(.systemBackground)
  }
}

final class ChatListTranslationCoordinator: ObservableObject {
  private let core = Core()
  private var task: Task<Void, Never>?

  func prime(items: [HomeChatItem]) {
    task?.cancel()
    task = Task(priority: .utility) { [core] in
      await core.setPrevious(items: items)
    }
  }

  func process(items: [HomeChatItem], currentPeers: Set<Peer>) {
    task?.cancel()
    task = Task(priority: .utility) { [core] in
      let itemsToProcess = await core.itemsNeedingTranslation(
        items: items,
        currentPeers: currentPeers
      )

      for item in itemsToProcess {
        if Task.isCancelled { return }
        guard let lastMessage = item.lastMessage else { continue }
        TranslationViewModel.translateMessages(
          for: item.peerId,
          messages: [FullMessage(from: lastMessage)]
        )
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  deinit {
    task?.cancel()
  }

  actor Core {
    private var previousById: [Int64: HomeChatItem] = [:]

    func setPrevious(items: [HomeChatItem]) async {
      previousById = await Self.makeDictionary(items: items)
    }

    func itemsNeedingTranslation(
      items: [HomeChatItem],
      currentPeers: Set<Peer>
    ) async -> [HomeChatItem] {
      let previous = previousById
      let newDict = await Self.makeDictionary(items: items)
      previousById = newDict

      return items.filter { item in
        previous[item.id] != item && !currentPeers.contains(item.peerId)
      }
    }

    @concurrent
    static func makeDictionary(items: [HomeChatItem]) async -> [Int64: HomeChatItem] {
      Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }
  }
}
