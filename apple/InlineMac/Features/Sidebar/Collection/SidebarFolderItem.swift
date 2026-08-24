import AppKit
import InlineMacUI
import SwiftUI

struct SidebarFolderItemView: View, Equatable {
  let title: String
  let emoji: String?
  let childCount: Int
  let unreadCount: Int
  let isExpanded: Bool
  let isDropTargeted: Bool
  let titleDimmed: Bool
  let size: SidebarItemSize
  let onToggle: () -> Void
  let onSetEmoji: (String) -> Void
  let onClose: () -> Void
  let onUngroup: () -> Void

  @State private var isHovering = false
  @State private var isEmojiPickerPresented = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title
      && lhs.emoji == rhs.emoji
      && lhs.childCount == rhs.childCount
      && lhs.unreadCount == rhs.unreadCount
      && lhs.isExpanded == rhs.isExpanded
      && lhs.isDropTargeted == rhs.isDropTargeted
      && lhs.titleDimmed == rhs.titleDimmed
      && lhs.size == rhs.size
  }

  var body: some View {
    HStack(spacing: 8) {
      Button {
        isEmojiPickerPresented = true
      } label: {
        SidebarFolderIcon(emoji: emoji, isExpanded: isExpanded, size: size.iconSize)
      }
      .buttonStyle(.plain)
      .help("Choose folder emoji")
      .accessibilityLabel("Choose emoji for \(title)")
      .background {
        EmojiPickerPopoverPresenter2(
          isPresented: $isEmojiPickerPresented,
          preferredEdge: .maxX
        ) { selectedEmoji in
          guard let emoji = EmojiPickerValue.normalizedEmoji(from: selectedEmoji) else { return }
          onSetEmoji(emoji)
        }
      }

      Button(action: onToggle) {
        HStack(spacing: 4) {
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.system(size: 13))
              .foregroundStyle(titleDimmed ? .secondary : .primary)
              .lineLimit(1)
            if size != .compact {
              Text("\(childCount) chat\(childCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }

          SidebarChatDisclosureIcon(
            isExpanded: isExpanded,
            rowHeight: size.rowHeight,
            animates: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
          )
          .frame(width: 16)

          Spacer(minLength: 4)

          if unreadCount > 0 {
            Text("\(unreadCount)")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, minHeight: size.rowHeight, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue("\(childCount) chats\(unreadCount > 0 ? ", \(unreadCount) unread" : "")")
    }
    .padding(.horizontal, Theme.sidebarItemInnerSpacing)
    .frame(maxWidth: .infinity, minHeight: size.rowHeight, alignment: .leading)
    .contentShape(.rect)
    .background(
      rowBackground,
      in: .rect(cornerRadius: Theme.sidebarItemRadius)
    )
    .padding(.horizontal, Theme.sidebarItemOuterSpacing)
    .onHover { hovering in
      if isHovering != hovering { isHovering = hovering }
    }
    .contextMenu {
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

struct SidebarFolderIcon: View {
  let emoji: String?
  let isExpanded: Bool
  let size: CGFloat

  var body: some View {
    Group {
      if let emoji, emoji.isEmpty == false {
        Text(emoji)
          .font(.system(size: min(size, 18)))
      } else {
        Image(systemName: isExpanded ? "folder.fill" : "folder")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .contentShape(.rect)
  }
}
