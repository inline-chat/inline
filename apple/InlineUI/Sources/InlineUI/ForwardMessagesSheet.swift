import InlineKit
import Logger
import SwiftUI

public struct ForwardMessagesSheet: View {
  public typealias ForwardMessagesSuccessHandler = (_ count: Int, _ singleTitle: String?) -> Void
  public typealias ForwardMessagesFailureHandler = (_ forwardedCount: Int, _ totalCount: Int) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtime

  private let messages: [FullMessage]
  private let onForwardSuccess: ForwardMessagesSuccessHandler?
  private let onForwardFailure: ForwardMessagesFailureHandler?
  private let onClose: (() -> Void)?
  private let log = Log.scoped("ForwardMessagesSheet")

  @StateObject private var homeViewModel: HomeViewModel
  @State private var searchText = ""
  @State private var isSending = false
  @State private var selectedPeers: Set<PeerKey> = []

  private var sendDisabled: Bool {
    selectedPeers.isEmpty || isSending
  }

  private struct PeerKey: Hashable {
    enum Kind: Hashable {
      case user
      case thread
    }

    let kind: Kind
    let id: Int64

    init?(peer: Peer) {
      switch peer {
        case let .user(id):
          kind = .user
          self.id = id
        case let .thread(id):
          kind = .thread
          self.id = id
      }
    }

    var peer: Peer {
      switch kind {
        case .user:
          return .user(id: id)
        case .thread:
          return .thread(id: id)
      }
    }
  }

  private var allChats: [HomeChatItem] {
    homeViewModel.myChats + homeViewModel.archivedChats
  }

  private var selectedChatItems: [HomeChatItem] {
    allChats.filter { item in
      guard let peerKey = PeerKey(peer: item.peerId) else { return false }
      return selectedPeers.contains(peerKey)
    }
  }

  private var filteredChats: [HomeChatItem] {
    filterChats(allChats)
  }

  public init(
    messages: [FullMessage],
    database: AppDatabase = AppDatabase.shared,
    onForwardSuccess: ForwardMessagesSuccessHandler? = nil,
    onForwardFailure: ForwardMessagesFailureHandler? = nil,
    onClose: (() -> Void)? = nil
  ) {
    self.messages = messages
    self.onForwardSuccess = onForwardSuccess
    self.onForwardFailure = onForwardFailure
    self.onClose = onClose
    _homeViewModel = StateObject(wrappedValue: HomeViewModel(db: database))
  }

  public var body: some View {
    NavigationStack {
      chatList
        .navigationTitle("Forward")
        .toolbar {
          #if os(macOS)
          ToolbarItem(placement: .cancellationAction) {
            closeButton
          }

          ToolbarItem(placement: .confirmationAction) {
            sendButton
          }
          #else
          ToolbarItem(placement: .topBarLeading) {
            closeButton
          }

          ToolbarItem(placement: .principal) {
            Text("Forward")
              .font(.headline)
          }

          ToolbarItem(placement: .topBarTrailing) {
            sendButton
          }
          #endif
        }
    }
    #if os(macOS)
    .frame(minWidth: 420, minHeight: 520)
    #endif
  }

  private var closeButton: some View {
    Button {
      closeSheet()
    } label: {
      Label("Cancel", systemImage: "xmark")
    }
    #if os(macOS)
    .labelStyle(.iconOnly)
    #else
    .labelStyle(.titleAndIcon)
    #endif
    #if os(macOS)
    .keyboardShortcut(.cancelAction)
    #endif
  }

  @ViewBuilder
  private var sendButton: some View {
    let button = Button("Done") {
      send()
    }
    .disabled(sendDisabled)

    #if os(macOS)
    button
      .keyboardShortcut(.defaultAction)
    #else
    if #available(iOS 26, *) {
      button
        .buttonStyle(.glassProminent)
    } else {
      button
        .buttonStyle(.borderedProminent)
    }
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
      if !selectedChatItems.isEmpty {
        VStack(spacing: 4) {
          Text("Forward")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
          selectedChipsRow
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

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

  private var selectedChipsRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(selectedChatItems, id: \.id) { item in
          selectedChip(item)
        }
      }
      .padding(.vertical, 2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func chatRow(_ item: HomeChatItem) -> some View {
    if let peerKey = PeerKey(peer: item.peerId) {
      let isSelected = selectedPeers.contains(peerKey)

      Button {
        toggleSelection(peerKey)
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
          if isSelected {
            selectedIndicator
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    } else {
      EmptyView()
    }
  }

  private var selectedIndicator: some View {
    ZStack {
      Circle()
        .fill(Color.accentColor)
      Image(systemName: "checkmark")
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.white)
    }
    .frame(width: 20, height: 20)
  }

  @ViewBuilder
  private func selectedChip(_ item: HomeChatItem) -> some View {
    if let peerKey = PeerKey(peer: item.peerId) {
      HStack(spacing: 4) {
        Text(chatTitle(item))
          .font(.caption2)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        Button {
          toggleSelection(peerKey)
        } label: {
          Image(systemName: "xmark")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule()
          .fill(Color.primary.opacity(0.07))
      )
    } else {
      EmptyView()
    }
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

  private func toggleSelection(_ peerKey: PeerKey) {
    withAnimation(.snappy) {
      if selectedPeers.contains(peerKey) {
        selectedPeers.remove(peerKey)
      } else {
        selectedPeers.insert(peerKey)
      }
    }
  }

  private func send() {
    guard !isSending else { return }
    guard let fromPeerId = messages.first?.peerId else {
      log.error("Missing fromPeerId for forward")
      return
    }

    let destinationPeers = Array(selectedPeers)
    let destinationCount = destinationPeers.count
    let destinationTitle = destinationCount == 1 ? selectedChatItems.first.map(chatTitle) : nil

    let messageIds = messages.map(\.message.messageId)
    isSending = true

    log.debug("Forwarding \(messageIds.count) messages to \(destinationCount) chats")

    Task {
      var forwardedCount = 0
      do {
        for peerKey in destinationPeers {
          _ = try await realtime.send(
            ForwardMessagesTransaction(
              fromPeerId: fromPeerId,
              toPeerId: peerKey.peer,
              messageIds: messageIds
            )
          )
          forwardedCount += 1
        }
        await MainActor.run {
          onForwardSuccess?(destinationCount, destinationTitle)
          closeSheet()
        }
      } catch {
        log.error("Failed to forward messages", error: error)
        await MainActor.run {
          onForwardFailure?(forwardedCount, destinationCount)
        }
      }
      await MainActor.run {
        isSending = false
      }
    }
  }
}
