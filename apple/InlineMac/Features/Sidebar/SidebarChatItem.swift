import InlineKit
import InlineMacUI
import Logger
import SwiftUI

enum SidebarItemSize: Equatable {
  case compact
  case large
}

struct SidebarChatItemView: Equatable, View {
  let item: SidebarViewModel.Item
  let selected: Bool
  var titleDimmed = false
  var size: SidebarItemSize = .large
  var onOpen: (() -> Void)?

  // Env and State
  @Environment(\.nav) private var nav
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dependencies) private var dependencies
  @State private var isHovered = false
  @State private var didOpenDuringPress = false
  @State private var isPressing = false

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private static let subtitleFont: Font = .system(size: 11)
  private static let innerPaddingHorizontal = 6.0
  private static let outerPaddingVertical = 0.0
  private static let unreadDotSize = 6.0
  private static let trailingAccessoryWidth = 14.0
  private static let compactIconSize = 22.0
  private static let largeIconSize = 32.0

  // Computed
  private var rowHeight: CGFloat {
    switch size {
      case .compact:
        30
      case .large:
        44
    }
  }

  private var iconSize: CGFloat {
    switch size {
      case .compact:
        Self.compactIconSize
      case .large:
        Self.largeIconSize
    }
  }

  private var peerId: Peer {
    item.peerId
  }

  private var showsPreview: Bool {
    size == .large && item.preview.isEmpty == false
  }

  private var titleAccessory: SidebarChatItemAccessory? {
    if item.unread, showsPreview {
      return nil
    }

    if item.unread {
      return .unread
    }

    if item.pinned {
      return .pinned
    }

    return nil
  }

  private var previewAccessory: SidebarChatItemAccessory? {
    item.unread && showsPreview ? .unread : nil
  }

  static func == (lhs: SidebarChatItemView, rhs: SidebarChatItemView) -> Bool {
    lhs.item == rhs.item
      && lhs.selected == rhs.selected
      && lhs.titleDimmed == rhs.titleDimmed
      && lhs.size == rhs.size
  }

  var body: some View {
    HStack(spacing: 0) {
      avatar
        .frame(width: iconSize, height: iconSize)
        .padding(.trailing, 8)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(item.title)
            .font(Self.titleFont)
            .foregroundStyle(titleColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

          if let titleAccessory {
            accessoryView(titleAccessory)
          }
        }

        if showsPreview {
          HStack(spacing: 5) {
            Text(item.preview)
              .font(Self.subtitleFont)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)

            if let previewAccessory {
              accessoryView(previewAccessory)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: rowHeight)
    .animation(.smoothSnappy, value: size)
    .animation(.smoothSnappy, value: item.unread)
    .animation(.smoothSnappy, value: item.pinned)
    // Inner paddings
    .padding(.horizontal, Self.innerPaddingHorizontal)
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .background(background)
    // Outer paddings
    .padding(.horizontal, -Theme.sidebarNativeDefaultEdgeInsets + 8)
    .padding(.vertical, Self.outerPaddingVertical)
    .onHover { isHovered = $0 }
    .simultaneousGesture(openOnMouseDownGesture)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction {
      open()
    }
    .contextMenu {
      Button {
        MainWindowOpenCoordinator.shared.openTab(.chat(peer: peerId))
      } label: {
        Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
      }

      Button {
        MainWindowOpenCoordinator.shared.openNewWindow(.chat(peer: peerId))
      } label: {
        Label("Open in New Window", systemImage: "macwindow")
      }

      Divider()

      Button {
        togglePin()
      } label: {
        Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash.fill" : "pin.fill")
      }

      Button {
        toggleReadUnread()
      } label: {
        Label(
          item.unread ? "Mark Read" : "Mark Unread",
          systemImage: item.unread ? "checkmark.message.fill" : "envelope.badge.fill"
        )
      }

      Button {
        toggleArchive()
      } label: {
        Label(item.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
      }
    }
  }

  private var unreadDot: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: Self.unreadDotSize, height: Self.unreadDotSize)
  }

  @ViewBuilder
  private func accessoryView(_ accessory: SidebarChatItemAccessory) -> some View {
    Group {
      switch accessory {
        case .unread:
          unreadDot
        case .pinned:
          Image(systemName: "pin.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
      }
    }
    .frame(width: Self.trailingAccessoryWidth, alignment: .center)
    .transition(.scale.combined(with: .opacity))
  }

  @ViewBuilder
  private var avatar: some View {
    if case let .chat(chat) = item.peer, size == .compact {
      SidebarThreadIcon(chat: chat, size: Self.compactIconSize)
    } else if let peer = item.peer {
      ChatIcon(peer: peer, size: iconSize)
    } else {
      Circle()
        .fill(Color.primary.opacity(0.08))
        .overlay {
          Image(systemName: "bubble.left")
            .font(.system(size: iconSize * 0.45, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if isActive {
      colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.07)
    } else if isHovered {
      colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    } else {
      .clear
    }
  }

  private var isActive: Bool {
    selected || isPressing
  }

  private var titleColor: Color {
    Color.primary.opacity(titleDimmed ? 0.8 : 1)
  }

  private var openOnMouseDownGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        openOnMouseDown()
      }
      .onEnded { _ in
        didOpenDuringPress = false
        isPressing = false
      }
  }

  private func openOnMouseDown() {
    guard didOpenDuringPress == false else { return }
    didOpenDuringPress = true
    isPressing = true
    open()
  }

  private func open() {
    if let onOpen {
      onOpen()
      return
    }

    if let dependencies {
      dependencies.requestOpenChat(peer: peerId)
      return
    }

    nav.open(.chat(peer: peerId))
  }

  private func togglePin() {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(peerId: peerId, pinned: !item.pinned)
      } catch {
        Log.shared.error("Failed to update pin status", error: error)
      }
    }
  }

  private func toggleReadUnread() {
    Task(priority: .userInitiated) {
      do {
        if item.unread {
          UnreadManager.shared.readAll(peerId, chatId: item.chatId)
          return
        }

        guard let dependencies else { return }
        try await dependencies.realtimeV2.send(.markAsUnread(peerId: peerId))
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }

  private func toggleArchive() {
    Task(priority: .userInitiated) {
      do {
        try await DataManager.shared.updateDialog(
          peerId: peerId,
          archived: !item.archived,
          spaceId: item.spaceId
        )

        if item.archived == false, nav.currentRoute.selectedPeer == peerId {
          await MainActor.run {
            nav.open(.empty)
          }
        }
      } catch {
        Log.shared.error("Failed to update archive state", error: error)
      }
    }
  }
}

private enum SidebarChatItemAccessory {
  case unread
  case pinned
}

#Preview {
  SidebarChatItemView(
    item: SidebarViewModel.Item(
      listItem: ChatListItem(chatItem: HomeChatItem(
        dialog: Dialog(optimisticForChat: .preview),
        user: nil,
        chat: Chat.preview,
        lastMessage: nil,
        space: nil
      ))
    )!,
    selected: true
  )
  .padding()
  .frame(width: 260)
}
