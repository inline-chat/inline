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

  public typealias ForwardMessagesSelectHandler = (_ destination: HomeChatItem, _ selection: ForwardMessagesSelection)
    -> Void
  public typealias ForwardMessagesSendHandler = @MainActor (
    _ destinations: [HomeChatItem],
    _ selection: ForwardMessagesSelection
  ) async -> Void

  @Environment(\.dismiss) private var dismiss

  private let messages: [FullMessage]
  private let onSelect: ForwardMessagesSelectHandler?
  private let onSend: ForwardMessagesSendHandler?
  private let onClose: (() -> Void)?
  private let log = Log.scoped("ForwardMessagesSheet")

  @StateObject private var homeViewModel: HomeViewModel
  @State private var searchText = ""
  @State private var isSelecting = false
  @State private var isSending = false
  @State private var selectedPeers: Set<Peer> = []

  private var supportsMultiSelect: Bool {
    onSend != nil
  }

  private var allChats: [HomeChatItem] {
    homeViewModel.myChats + homeViewModel.archivedChats
  }

  private var filteredChats: [HomeChatItem] {
    filterChats(allChats)
  }

  private var selectedCount: Int {
    selectedPeers.count
  }

  private var shouldShowSendButton: Bool {
    supportsMultiSelect && isSelecting && selectedCount > 0
  }

  private var selectedChats: [HomeChatItem] {
    guard !selectedPeers.isEmpty else { return [] }
    return allChats.filter { selectedPeers.contains($0.peerId) }
  }

  private var navigationTitle: String {
    selectedCount > 0 ? "\(selectedCount) Selected" : "Forward"
  }

  public init(
    messages: [FullMessage],
    database: AppDatabase = AppDatabase.shared,
    onSelect: ForwardMessagesSelectHandler? = nil,
    onSend: ForwardMessagesSendHandler? = nil,
    onClose: (() -> Void)? = nil
  ) {
    self.messages = messages
    self.onSelect = onSelect
    self.onSend = onSend
    self.onClose = onClose
    _homeViewModel = StateObject(wrappedValue: HomeViewModel(db: database))
  }

  public var body: some View {
    NavigationStack {
      chatList
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
    }
    #if os(macOS)
    .onExitCommand(perform: closeSheet)
    .frame(minWidth: 420, minHeight: 520)
    #endif
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    if supportsMultiSelect {
      ToolbarItem(placement: .primaryAction) {
        selectToggleButton
      }
      if shouldShowSendButton {
        ToolbarItem(placement: .confirmationAction) {
          sendButton
        }
      }
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
    .disabled(isSending)
  }

  @ViewBuilder
  private func chatRow(_ item: HomeChatItem) -> some View {
    Button {
      handleSelection(item)
    } label: {
      HStack(spacing: 10) {
        if supportsMultiSelect, isSelecting {
          selectionIndicator(item)
        }
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

  private var selectToggleButton: some View {
    toolbarButton(isSelecting ? "Cancel" : "Select") {
      if isSelecting {
        selectedPeers.removeAll()
        isSelecting = false
      } else {
        isSelecting = true
      }
    }
  }

  private var sendButton: some View {
    toolbarButton("Send", prominent: true) {
      handleSend()
    }
  }

  @ViewBuilder
  private func toolbarButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    let button = Button(title, action: action)
      .disabled(isSending)
      .padding(.horizontal, 8)
    #if os(iOS)
    if #available(iOS 26, *) {
      if prominent {
        button.buttonStyle(.glassProminent)
      } else {
        button.buttonStyle(.plain)
      }
    } else {
      button
    }
    #else
    button
    #endif
  }

  @ViewBuilder
  private func selectionIndicator(_ item: HomeChatItem) -> some View {
    let isSelected = selectedPeers.contains(item.peerId)
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      .font(.system(size: 18, weight: .medium))
      .frame(width: 20)
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
    if supportsMultiSelect, isSelecting {
      toggleSelection(for: item)
      return
    }

    guard let selection = buildSelection() else { return }
    onSelect?(item, selection)
    closeSheet()
  }

  private func handleSend() {
    guard let selection = buildSelection() else { return }
    let destinations = selectedChats
    guard !destinations.isEmpty else { return }
    guard let onSend else {
      log.error("Missing onSend handler for multi-forward")
      return
    }

    isSending = true
    Task { @MainActor in
      await onSend(destinations, selection)
      isSending = false
      closeSheet()
    }
  }

  private func closeSheet() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }

  private func toggleSelection(for item: HomeChatItem) {
    let peerId = item.peerId
    if selectedPeers.contains(peerId) {
      selectedPeers.remove(peerId)
    } else {
      selectedPeers.insert(peerId)
    }
  }

  private func buildSelection() -> ForwardMessagesSelection? {
    guard let fromPeerId = messages.first?.peerId,
          let sourceChatId = messages.first?.chatId
    else {
      log.error("Missing forward source metadata")
      return nil
    }
    let messageIds = messages.map(\.message.messageId)
    guard let previewMessageId = messageIds.first else {
      log.error("Missing forward message ids")
      return nil
    }

    return ForwardMessagesSelection(
      fromPeerId: fromPeerId,
      sourceChatId: sourceChatId,
      messageIds: messageIds,
      previewMessageId: previewMessageId
    )
  }
}
