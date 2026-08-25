import AppKit
import InlineMacUI
import SwiftUI

struct SidebarFolderItemView: View, Equatable {
  let title: String
  let emoji: String?
  let childCount: Int
  let unreadCount: Int
  let prominentUnreadCount: Int
  let unreadBadgeStyle: UnreadBadgeStyle
  let isPinned: Bool
  let isExpanded: Bool
  let isDropTargeted: Bool
  let titleDimmed: Bool
  let size: SidebarItemSize
  let onToggle: () -> Void
  let onSetEmoji: (String) -> Void
  let onTogglePin: () -> Void
  let onRename: () -> Void
  let onClose: () -> Void
  let onUngroup: () -> Void

  @State private var isHovering = false
  @State private var isEmojiPickerPresented = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title
      && lhs.emoji == rhs.emoji
      && lhs.childCount == rhs.childCount
      && lhs.unreadCount == rhs.unreadCount
      && lhs.prominentUnreadCount == rhs.prominentUnreadCount
      && lhs.unreadBadgeStyle == rhs.unreadBadgeStyle
      && lhs.isPinned == rhs.isPinned
      && lhs.isExpanded == rhs.isExpanded
      && lhs.isDropTargeted == rhs.isDropTargeted
      && lhs.titleDimmed == rhs.titleDimmed
      && lhs.size == rhs.size
  }

  var body: some View {
    ZStack(alignment: .leading) {
      Button(action: onToggle) {
        HStack(spacing: 0) {
          Color.clear
            .frame(width: size.iconSize, height: size.iconSize)
            .padding(.trailing, 8)

          Text(title)
            .font(.system(size: 13))
            .foregroundStyle(titleDimmed ? .secondary : .primary)
            .lineLimit(1)

          Spacer(minLength: 4)

          UnreadBadge(
            unreadCount: isExpanded ? 0 : unreadCount,
            prominent: prominentUnreadCount > 0,
            style: unreadBadgeStyle,
            dotSize: Theme.sidebarItemUnreadDotSize
          )
          .fixedSize()
        }
        .padding(.leading, Theme.sidebarItemInnerSpacing)
        .padding(.trailing, Theme.sidebarItemOuterSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue("\(childCount) chats\(unreadCount > 0 ? ", \(unreadCount) unread" : "")")

      Button(action: onToggle) {
        SidebarChatDisclosureIcon(
          isExpanded: isExpanded,
          rowHeight: size.rowHeight,
          animates: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
      }
      .buttonStyle(.plain)
      .offset(x: (Theme.sidebarItemInnerSpacing - 24) / 2)
      .help(isExpanded ? "Collapse folder" : "Expand folder")
      .accessibilityLabel(isExpanded ? "Collapse folder" : "Expand folder")

      Button(action: onToggle) {
        SidebarFolderIcon(emoji: emoji, size: size.iconSize)
      }
      .buttonStyle(.plain)
      .padding(.leading, Theme.sidebarItemInnerSpacing)
      .help(isExpanded ? "Collapse folder" : "Expand folder")
      .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
      .background {
        EmojiPickerPopoverPresenter2(
          isPresented: $isEmojiPickerPresented,
          preferredEdge: .maxX
        ) { selectedEmoji in
          guard let emoji = EmojiPickerValue.normalizedEmoji(from: selectedEmoji) else { return }
          onSetEmoji(emoji)
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: SidebarCollectionRow.paintedItemHeight(for: size.rowHeight))
    .contentShape(.rect)
    .background(
      rowBackground,
      in: .rect(cornerRadius: Theme.sidebarItemRadius)
    )
    .padding(.horizontal, 8)
    .padding(.vertical, SidebarCollectionRow.itemVisualEdgeInset)
    .onHover { hovering in
      if isHovering != hovering { isHovering = hovering }
    }
    .contextMenu {
      Button(
        isPinned ? "Unpin" : "Pin",
        systemImage: isPinned ? "pin.slash.fill" : "pin.fill",
        action: onTogglePin
      )

      Button("Rename Folder…", systemImage: "pencil", action: onRename)

      Button("Change Emoji…", systemImage: "face.smiling") {
        isEmojiPickerPresented = true
      }

      Divider()

      if childCount == 0 {
        Button("Delete Folder", systemImage: "trash", role: .destructive, action: onUngroup)
      } else {
        Button("Close Folder and Chats", systemImage: "xmark", role: .destructive, action: onClose)
        Button("Ungroup (Keep Chats)", systemImage: "folder.badge.minus", action: onUngroup)
      }
    }
  }

  private var rowBackground: Color {
    if isDropTargeted {
      return Color.accentColor.opacity(0.14)
    }
    return isHovering ? Color.primary.opacity(0.06) : .clear
  }
}

struct RenameSidebarFolderSheet: View {
  let onSave: (String, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var emoji: String
  @FocusState private var isTitleFocused: Bool

  init(
    initialTitle: String,
    initialEmoji: String?,
    onSave: @escaping (String, String?) -> Void
  ) {
    self.onSave = onSave
    _title = State(initialValue: initialTitle)
    _emoji = State(initialValue: initialEmoji ?? "")
  }

  var body: some View {
    VStack(spacing: 16) {
      Text("Rename Folder")
        .font(.title3)
        .fontWeight(.semibold)

      HStack(spacing: 8) {
        EmojiTextFieldPicker(
          emoji: $emoji,
          size: 28,
          placeholderSystemImage: "folder",
          accessibilityLabel: "Folder emoji"
        )

        TextField("Folder Name", text: $title)
          .textFieldStyle(.roundedBorder)
          .focused($isTitleFocused)
          .onSubmit(save)
      }

      HStack {
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Save", action: save)
          .disabled(!canSave)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear {
      isTitleFocused = true
    }
  }

  private var normalizedTitle: String {
    title
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  private var canSave: Bool {
    normalizedTitle.isEmpty == false && normalizedTitle.unicodeScalars.count <= 80
  }

  private func save() {
    guard canSave else { return }
    onSave(normalizedTitle, EmojiPickerValue.normalizedEmoji(from: emoji))
    dismiss()
  }
}

struct SidebarFolderEmptyRow: View {
  let size: SidebarItemSize

  var body: some View {
    Text(
      "Drop a chat here",
      comment: "Passive drop instruction inside an expanded empty sidebar folder."
    )
      .font(.system(size: 13))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, minHeight: size.rowHeight, alignment: .leading)
      .padding(.leading, leadingInset)
      .padding(.horizontal, Theme.sidebarItemOuterSpacing)
  }

  private var leadingInset: CGFloat {
    Theme.sidebarItemInnerSpacing
      + SidebarChatRowLayout.contentIndentation(level: 1, size: size, showsIcon: true)
      + size.iconSize
      + 8
  }
}

struct SidebarFolderIcon: View {
  let emoji: String?
  let size: CGFloat

  var body: some View {
    Group {
      if let emoji, emoji.isEmpty == false {
        Text(emoji)
          .font(.system(size: min(size, 18)))
      } else {
        Image(systemName: "folder.fill")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .contentShape(.rect)
  }
}
