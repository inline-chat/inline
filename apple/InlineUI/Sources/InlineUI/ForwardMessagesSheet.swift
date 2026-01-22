import InlineKit
import Logger
import SwiftUI

public struct ForwardMessagesSheet: View {
  public struct ForwardMessagesSelection: Sendable {
    public let fromPeerId: Peer
    public let sourceChatId: Int64
    public let messageIds: [Int64]
    public let previewMessageId: Int64

    public init(
      fromPeerId: Peer,
      sourceChatId: Int64,
      messageIds: [Int64],
      previewMessageId: Int64
    ) {
      self.fromPeerId = fromPeerId
      self.sourceChatId = sourceChatId
      self.messageIds = messageIds
      self.previewMessageId = previewMessageId
    }
  }

  public typealias ForwardMessagesSelectHandler = (_ destination: HomeChatItem, _ selection: ForwardMessagesSelection) -> Void

  @Environment(\.dismiss) private var dismiss

  private let messages: [FullMessage]
  private let onSelect: ForwardMessagesSelectHandler?
  private let onClose: (() -> Void)?

  @StateObject private var homeViewModel: HomeViewModel
  @State private var searchText = ""
  private let log = Log.scoped("ForwardMessagesSheet")

  private var allChats: [HomeChatItem] {
    homeViewModel.myChats + homeViewModel.archivedChats
  }

  private var filteredChats: [HomeChatItem] {
    filterChats(allChats)
  }

  public init(
    messages: [FullMessage],
    database: AppDatabase = AppDatabase.shared,
    onSelect: ForwardMessagesSelectHandler? = nil,
    onClose: (() -> Void)? = nil
  ) {
    self.messages = messages
    self.onSelect = onSelect
    self.onClose = onClose
    _homeViewModel = StateObject(wrappedValue: HomeViewModel(db: database))
  }

  public var body: some View {
    NavigationStack {
      chatList
        .navigationTitle("Forward")
    }
    #if os(macOS)
    .frame(minWidth: 420, minHeight: 520)
    #endif
  }

  private func closeSheet() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  private var chatList: some View {
    List {
      if !filteredChats.isEmpty {
        ForEach(filteredChats, id: \.id) { item in
          chatRow(item)
        }
      } else {
        Text("No chats found")
          .foregroundStyle(.secondary)
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }
    }
    .searchable(text: $searchText)
  }

  @ViewBuilder
  private func chatRow(_ item: HomeChatItem) -> some View {
    Button {
      handleSelection(item)
    } label: {
      HStack(spacing: 10) {
        avatarView(item)
        VStack(alignment: .leading, spacing: 1) {
          Text(chatTitle(item))
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let spaceName = item.space?.name, !spaceName.isEmpty {
            Text(spaceName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
  }

  @ViewBuilder
  private func avatarView(_ item: HomeChatItem) -> some View {
    let size: CGFloat = 28
    if let userInfo = item.user {
      UserAvatar(userInfo: userInfo, size: size)
    } else if let chat = item.chat {
      InitialsCircle(name: chat.title ?? "Chat", size: size)
    } else {
      Circle()
        .fill(Color.gray.opacity(0.3))
        .frame(width: size, height: size)
    }
  }

  private func filterChats(_ items: [HomeChatItem]) -> [HomeChatItem] {
    guard !searchText.isEmpty else { return items }
    return items.filter { item in
      let title = chatTitle(item)
      return title.localizedCaseInsensitiveContains(searchText)
    }
  }

  private func chatTitle(_ item: HomeChatItem) -> String {
    if let user = item.user?.user {
      return user.displayName
    }

    if let chat = item.chat {
      return chat.title ?? "Chat"
    }

    return "Chat"
  }

  private func handleSelection(_ item: HomeChatItem) {
    guard let fromPeerId = messages.first?.peerId,
          let sourceChatId = messages.first?.chatId
    else {
      log.error("Missing forward source metadata")
      return
    }
    let messageIds = messages.map(\.message.messageId)
    guard let previewMessageId = messageIds.first else {
      log.error("Missing forward message ids")
      return
    }

    onSelect?(
      item,
      ForwardMessagesSelection(
        fromPeerId: fromPeerId,
        sourceChatId: sourceChatId,
        messageIds: messageIds,
        previewMessageId: previewMessageId
      )
    )
    closeSheet()
  }
}
