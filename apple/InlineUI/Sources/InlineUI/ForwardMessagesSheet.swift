import InlineKit
import Logger
import SwiftUI
#if os(macOS)
import AppKit
#endif

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

  final class SheetModel: ObservableObject {
    @Published var searchText = ""
    @Published var isSelecting = false
    @Published var isSending = false
    @Published var selectedPeers: Set<Peer> = []
    #if os(macOS)
    @Published var isSearchFocused = false
    @Published var highlightedChatId: Int64?
    #endif
  }

  @Environment(\.dismiss) private var dismiss

  private let messages: [FullMessage]
  private let database: AppDatabase
  private let onSelect: ForwardMessagesSelectHandler?
  private let onSend: ForwardMessagesSendHandler?
  private let onClose: (() -> Void)?
  private let log = Log.scoped("ForwardMessagesSheet")

  @StateObject private var homeViewModel: HomeViewModel
  @StateObject private var model: SheetModel
  #if os(macOS)
  @State private var macKeyMonitor: Any?
  #endif

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
    model.selectedPeers.count
  }

  private var shouldShowSendButton: Bool {
    supportsMultiSelect && model.isSelecting && selectedCount > 0
  }

  private var selectedChats: [HomeChatItem] {
    guard !model.selectedPeers.isEmpty else { return [] }
    return allChats.filter { model.selectedPeers.contains($0.peerId) }
  }

  private var navigationTitle: String {
    selectedCount > 0 ? "\(selectedCount) Selected" : "Forward"
  }

  #if os(macOS)
  private var filteredChatIds: [Int64] {
    filteredChats.map(\.id)
  }
  #endif

  public init(
    messages: [FullMessage],
    database: AppDatabase = AppDatabase.shared,
    onSelect: ForwardMessagesSelectHandler? = nil,
    onSend: ForwardMessagesSendHandler? = nil,
    onClose: (() -> Void)? = nil
  ) {
    self.messages = messages
    self.database = database
    self.onSelect = onSelect
    self.onSend = onSend
    self.onClose = onClose
    _homeViewModel = StateObject(wrappedValue: HomeViewModel(db: database))
    _model = StateObject(wrappedValue: SheetModel())
  }

  public var body: some View {
    #if os(macOS)
    MacForwardMessagesSheetView(
      model: model,
      filteredChats: filteredChats,
      navigationTitle: navigationTitle,
      shouldShowSendButton: shouldShowSendButton,
      supportsMultiSelect: supportsMultiSelect,
      onClose: closeSheet,
      onToggleSelectionMode: toggleSelectionMode,
      onSend: handleSend,
      onActivateChat: handleMacRowActivation
    )
    .onExitCommand(perform: handleExitCommand)
    .frame(minWidth: 420, minHeight: 520)
    .onAppear {
      syncHighlightedChat()
      focusSearchField()
      installMacKeyMonitor()
    }
    .onDisappear {
      removeMacKeyMonitor()
    }
    .onChange(of: filteredChatIds) {
      syncHighlightedChat()
    }
    #else
    IOSForwardMessagesSheetView(
      model: model,
      filteredChats: filteredChats,
      navigationTitle: navigationTitle,
      shouldShowSendButton: shouldShowSendButton,
      supportsMultiSelect: supportsMultiSelect,
      onToggleSelectionMode: toggleSelectionMode,
      onSend: handleSend,
      onActivateChat: handleSelection
    )
    #endif
  }

  private func filterChats(_ items: [HomeChatItem]) -> [HomeChatItem] {
    guard !model.searchText.isEmpty else { return items }
    return items.filter { item in
      let title = item.user?.user.displayName
        ?? item.chat?.humanReadableTitle
        ?? "Chat"
      return title.localizedCaseInsensitiveContains(model.searchText)
    }
  }

  #if os(macOS)
  private func installMacKeyMonitor() {
    guard macKeyMonitor == nil else { return }
    macKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleMacKeyDown(event)
    }
  }

  private func removeMacKeyMonitor() {
    guard let macKeyMonitor else { return }
    NSEvent.removeMonitor(macKeyMonitor)
    self.macKeyMonitor = nil
  }

  private func handleMacKeyDown(_ event: NSEvent) -> NSEvent? {
    let textInputFocused = isTextInputFocused(in: event.window)

    if let action = ForwardMessagesMacKeyBindings.action(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags,
      isTextInputFocused: textInputFocused,
      hasSearchText: !model.searchText.isEmpty
    ) {
      switch action {
        case let .moveHighlightedChat(offset):
          moveHighlightedChat(by: offset)
          return nil
        case .toggleHighlightedSelection:
          return handleSpaceKey() ? nil : event
        case .activateHighlightedChat:
          return activateHighlightedChat() ? nil : event
        case .backspaceSearch:
          focusSearchField()
          model.searchText.removeLast()
          return nil
      }
    }

    guard !textInputFocused,
          let characters = event.characters,
          characters.contains(where: { !$0.isWhitespace }),
          characters.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return event
    }

    focusSearchField()
    model.searchText.append(characters)
    return nil
  }

  private func moveHighlightedChat(by offset: Int) {
    guard !filteredChats.isEmpty else {
      model.highlightedChatId = nil
      return
    }

    let currentIndex = filteredChats.firstIndex { $0.id == model.highlightedChatId } ?? -1
    let nextIndex = min(max(currentIndex + offset, 0), filteredChats.count - 1)
    model.highlightedChatId = filteredChats[nextIndex].id
  }

  private func activateHighlightedChat() -> Bool {
    guard let item = highlightedChatItem() else { return false }
    handleMacRowActivation(item)
    return true
  }

  private func handleSpaceKey() -> Bool {
    guard let item = highlightedChatItem() else { return false }

    if !model.isSelecting {
      model.isSelecting = true
    }

    toggleSelection(for: item)
    return true
  }

  private func highlightedChatItem() -> HomeChatItem? {
    if let highlightedChatId = model.highlightedChatId,
       let item = filteredChats.first(where: { $0.id == highlightedChatId }) {
      return item
    }

    guard let firstItem = filteredChats.first else {
      return nil
    }

    model.highlightedChatId = firstItem.id
    return firstItem
  }

  private func syncHighlightedChat() {
    guard !filteredChats.isEmpty else {
      model.highlightedChatId = nil
      return
    }

    guard let highlightedChatId = model.highlightedChatId,
          filteredChats.contains(where: { $0.id == highlightedChatId })
    else {
      model.highlightedChatId = filteredChats[0].id
      return
    }

    model.highlightedChatId = highlightedChatId
  }

  private func focusSearchField() {
    DispatchQueue.main.async {
      model.isSearchFocused = true
    }
  }

  private func isTextInputFocused(in window: NSWindow?) -> Bool {
    guard let firstResponder = window?.firstResponder else { return false }
    return firstResponder is NSTextField
      || firstResponder is NSTextView
      || firstResponder is NSSecureTextField
      || (firstResponder is NSText && (firstResponder as? NSText)?.delegate is NSTextField)
  }

  private func handleMacRowActivation(_ item: HomeChatItem) {
    model.highlightedChatId = item.id
    handleSelection(item)
  }
  #endif

  private func handleExitCommand() {
    #if os(macOS)
    if model.isSelecting {
      model.selectedPeers.removeAll()
      model.isSelecting = false
      return
    }
    #endif
    closeSheet()
  }

  private func toggleSelectionMode() {
    if model.isSelecting {
      model.selectedPeers.removeAll()
      model.isSelecting = false
    } else {
      model.isSelecting = true
    }
  }

  private func handleSelection(_ item: HomeChatItem) {
    if supportsMultiSelect, model.isSelecting {
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

    model.isSending = true
    Task { @MainActor in
      await onSend(destinations, selection)
      model.isSending = false
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
    if model.selectedPeers.contains(peerId) {
      model.selectedPeers.remove(peerId)
    } else {
      model.selectedPeers.insert(peerId)
    }
  }

  private func buildSelection() -> ForwardMessagesSelection? {
    guard let sourceMessage = messages.first else {
      log.error("Missing forward source metadata")
      return nil
    }

    let sourceChatId = sourceMessage.chatId
    let fromPeerId: Peer
    if let sourceChat = try? database.reader.read({ db in
      try Chat.fetchOne(db, id: sourceChatId)
    }) {
      if let peerUserId = sourceChat.peerUserId {
        fromPeerId = .user(id: peerUserId)
      } else {
        fromPeerId = .thread(id: sourceChat.id)
      }
    } else {
      fromPeerId = sourceMessage.peerId
      log.warning("Falling back to message peer for forward source chatId=\(sourceChatId)")
    }

    let messageIds = messages.map(\.message.messageId)
    guard let previewMessageId = messageIds.first else {
      log.error("Missing forward message ids")
      return nil
    }

    if messages.contains(where: { $0.chatId != sourceChatId }) {
      log.error("Forward selection contains messages from multiple chats sourceChatId=\(sourceChatId)")
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

#if os(iOS)
private struct IOSForwardMessagesSheetView: View {
  @ObservedObject var model: ForwardMessagesSheet.SheetModel
  let filteredChats: [HomeChatItem]
  let navigationTitle: String
  let shouldShowSendButton: Bool
  let supportsMultiSelect: Bool
  let onToggleSelectionMode: () -> Void
  let onSend: () -> Void
  let onActivateChat: (HomeChatItem) -> Void

  var body: some View {
    NavigationStack {
      List {
        if !filteredChats.isEmpty {
          ForEach(filteredChats, id: \.id) { item in
            Button {
              onActivateChat(item)
            } label: {
              HStack(spacing: 10) {
                if supportsMultiSelect, model.isSelecting {
                  Image(systemName: model.selectedPeers.contains(item.peerId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedPeers.contains(item.peerId) ? Color.accentColor : Color.secondary)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 20)
                }

                iosAvatarView(item)

                VStack(alignment: .leading, spacing: 1) {
                  Text(item.user?.user.displayName ?? item.chat?.humanReadableTitle ?? "Chat")
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
        } else {
          Text("No chats found")
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
      }
      .searchable(text: $model.searchText)
      .disabled(model.isSending)
      .navigationTitle(navigationTitle)
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        if supportsMultiSelect {
          ToolbarItem(placement: .primaryAction) {
            iosToolbarButton(model.isSelecting ? "Cancel" : "Select") {
              onToggleSelectionMode()
            }
          }
          if shouldShowSendButton {
            ToolbarItem(placement: .confirmationAction) {
              iosToolbarButton("Send", prominent: true) {
                onSend()
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func iosAvatarView(_ item: HomeChatItem) -> some View {
    let size: CGFloat = 28
    if let userInfo = item.user {
      UserAvatar(userInfo: userInfo, size: size)
    } else if let chat = item.chat {
      InitialsCircle(name: chat.humanReadableTitle ?? "Chat", size: size)
    } else {
      Circle()
        .fill(Color.gray.opacity(0.3))
        .frame(width: size, height: size)
    }
  }

  @ViewBuilder
  private func iosToolbarButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    let button = Button(title, action: action)
      .disabled(model.isSending)
      .padding(.horizontal, 8)

    if #available(iOS 26, *) {
      if prominent {
        button.buttonStyle(.glassProminent)
      } else {
        button.buttonStyle(.plain)
      }
    } else {
      button
    }
  }
}
#endif

#if os(macOS)
private struct MacForwardMessagesSheetView: View {
  @ObservedObject var model: ForwardMessagesSheet.SheetModel
  let filteredChats: [HomeChatItem]
  let navigationTitle: String
  let shouldShowSendButton: Bool
  let supportsMultiSelect: Bool
  let onClose: () -> Void
  let onToggleSelectionMode: () -> Void
  let onSend: () -> Void
  let onActivateChat: (HomeChatItem) -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 12) {
        header
        NativeSearchField(
          text: $model.searchText,
          isFocused: $model.isSearchFocused,
          placeholder: "Search chats"
        )
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Search chats")
        .disabled(model.isSending)
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 12)

      Divider()

      List {
        if !filteredChats.isEmpty {
          ForEach(filteredChats, id: \.id) { item in
            Button {
              onActivateChat(item)
            } label: {
              HStack(spacing: 9) {
                if supportsMultiSelect, model.isSelecting {
                  Image(systemName: model.selectedPeers.contains(item.peerId) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedPeers.contains(item.peerId) ? Color.accentColor : Color.secondary)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 18)
                }

                macAvatarView(item)

                VStack(alignment: .leading, spacing: 1) {
                  Text(item.user?.user.displayName ?? item.chat?.humanReadableTitle ?? "Chat")
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

                Spacer(minLength: 0)
              }
              .padding(.horizontal, 6)
              .padding(.vertical, 5)
              .background {
                if isSelected(item) {
                  RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(backgroundColor(for: item))
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            .listRowBackground(Color.clear)
          }
        } else {
          Text("No chats found")
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
      }
      .disabled(model.isSending)
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      closeButton

      Spacer(minLength: 0)

      HStack(spacing: 8) {
        if shouldShowSendButton {
          actionButton("Send", prominent: true) {
            onSend()
          }
        }
        if supportsMultiSelect {
          actionButton(model.isSelecting ? "Cancel" : "Select") {
            onToggleSelectionMode()
          }
        }
      }
    }
    .overlay {
      Text(navigationTitle)
        .font(.headline)
        .lineLimit(1)
        .allowsHitTesting(false)
    }
  }

  private var closeButton: some View {
    Button(action: onClose) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 28, height: 28)
    }
    .labelStyle(.iconOnly)
    .buttonBorderShape(.circle)
    .controlSize(.regular)
    .modifier(MacCloseButtonStyle())
    .foregroundStyle(.secondary)
    .help("Close")
  }

  @ViewBuilder
  private func actionButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void)
    -> some View
  {
    let button = Button(title, action: action)
      .disabled(model.isSending)
      .buttonBorderShape(.capsule)

    if #available(macOS 26.0, *) {
      if prominent {
        button
          .buttonStyle(.glassProminent)
          .controlSize(.regular)
      } else {
        button
          .buttonStyle(.glass)
          .controlSize(.regular)
      }
    } else {
      if prominent {
        button
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
      } else {
        button
          .buttonStyle(.bordered)
          .controlSize(.regular)
      }
    }
  }

  @ViewBuilder
  private func macAvatarView(_ item: HomeChatItem) -> some View {
    let size: CGFloat = 28
    if let userInfo = item.user {
      UserAvatar(userInfo: userInfo, size: size)
    } else if let chat = item.chat {
      InitialsCircle(name: chat.humanReadableTitle ?? "Chat", size: size)
    } else {
      Circle()
        .fill(Color.gray.opacity(0.3))
        .frame(width: size, height: size)
    }
  }

  private func isSelected(_ item: HomeChatItem) -> Bool {
    if model.isSelecting, model.selectedPeers.contains(item.peerId) {
      return true
    }
    return model.highlightedChatId == item.id
  }

  private func backgroundColor(for item: HomeChatItem) -> Color {
    if model.isSelecting, model.selectedPeers.contains(item.peerId) {
      return Color.accentColor.opacity(model.highlightedChatId == item.id ? 0.24 : 0.16)
    }

    guard model.highlightedChatId == item.id else {
      return .clear
    }

    if #available(macOS 26.0, *) {
      return Color.primary.opacity(0.08)
    }

    return Color.accentColor.opacity(0.10)
  }
}

private struct NativeSearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let placeholder: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let searchField = NSSearchField(frame: .zero)
    searchField.delegate = context.coordinator
    searchField.placeholderString = placeholder
    searchField.sendsSearchStringImmediately = true
    searchField.target = context.coordinator
    searchField.action = #selector(Coordinator.submit)
    searchField.controlSize = .large
    return searchField
  }

  func updateNSView(_ searchField: NSSearchField, context: Context) {
    if searchField.stringValue != text {
      searchField.stringValue = text
    }
    if searchField.placeholderString != placeholder {
      searchField.placeholderString = placeholder
    }

    if isFocused, searchField.window?.firstResponder !== searchField.currentEditor() {
      searchField.window?.makeFirstResponder(searchField)
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    @Binding private var text: String
    @Binding private var isFocused: Bool

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      isFocused = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      isFocused = false
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let searchField = notification.object as? NSSearchField else { return }
      if text != searchField.stringValue {
        text = searchField.stringValue
      }
    }

    @objc func submit() {}
  }
}

private struct MacCloseButtonStyle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .buttonStyle(.glass)
    } else {
      content
        .buttonStyle(.bordered)
    }
  }
}
#endif
