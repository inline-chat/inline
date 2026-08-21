import AppKit
import InlineMacUI
import SwiftUI

struct SidebarFolderItemView: View, Equatable {
  let title: String
  let childCount: Int
  let unreadCount: Int
  let isExpanded: Bool
  let titleDimmed: Bool
  let size: SidebarItemSize
  let onToggle: () -> Void
  let onClose: () -> Void
  let onUngroup: () -> Void

  @State private var isHovering = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title
      && lhs.childCount == rhs.childCount
      && lhs.unreadCount == rhs.unreadCount
      && lhs.isExpanded == rhs.isExpanded
      && lhs.titleDimmed == rhs.titleDimmed
      && lhs.size == rhs.size
  }

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 8) {
        SidebarChatDisclosureIcon(
          isExpanded: isExpanded,
          rowHeight: size.rowHeight,
          animates: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        .frame(width: 16)

        Image(systemName: isExpanded ? "folder.fill" : "folder")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: size.iconSize, height: size.iconSize)

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

        Spacer(minLength: 4)

        if unreadCount > 0 {
          Text("\(unreadCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
        }

        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .accessibilityLabel("Close folder and chats")
      }
      .padding(.horizontal, Theme.sidebarItemInnerSpacing)
      .frame(maxWidth: .infinity, minHeight: size.rowHeight, alignment: .leading)
      .contentShape(.rect)
      .background(
        isHovering ? Color.primary.opacity(0.06) : .clear,
        in: .rect(cornerRadius: Theme.sidebarItemRadius)
      )
      .padding(.horizontal, Theme.sidebarItemOuterSpacing)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      if isHovering != hovering { isHovering = hovering }
    }
    .contextMenu {
      Button("Close Folder and Chats", systemImage: "xmark", role: .destructive, action: onClose)
      Button("Ungroup (Keep Chats)", systemImage: "folder.badge.minus", action: onUngroup)
    }
    .accessibilityLabel(title)
    .accessibilityValue("\(childCount) chats\(unreadCount > 0 ? ", \(unreadCount) unread" : "")")
  }
}
