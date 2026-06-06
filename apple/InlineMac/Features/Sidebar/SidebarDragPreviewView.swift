import InlineKit
import InlineMacUI
import SwiftUI

struct SidebarDragPreviewView: View {
  let item: SidebarViewModel.Item
  let rowSize: CGSize

  @Environment(\.colorScheme) private var colorScheme

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private static let replyThreadTitleFont: Font = .system(size: 12, weight: .regular)
  private static let parentTitleFont: Font = .system(size: 10, weight: .regular)
  private static let subtitleFont: Font = .system(size: 11)
  private static let innerPaddingHorizontal = 6.0
  private static let unreadDotSize = 6.0

  private var isCompact: Bool {
    rowSize.height <= 32
  }

  private var iconSize: CGFloat {
    isCompact ? 22 : 32
  }

  private var showsPreview: Bool {
    !isCompact && item.preview.isEmpty == false && item.parentTitle == nil
  }

  var body: some View {
    HStack(spacing: 0) {
      avatar
        .frame(width: iconSize, height: iconSize)
        .padding(.trailing, 8)

      VStack(alignment: .leading, spacing: 2) {
        titleBlock

        if showsPreview {
          HStack(spacing: 5) {
            Text(item.preview)
              .font(Self.subtitleFont)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)

            if item.unread {
              unreadDot
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, Self.innerPaddingHorizontal)
    .frame(width: rowSize.width, height: rowSize.height)
    .background {
      RoundedRectangle(cornerRadius: Theme.sidebarItemRadius, style: .continuous)
        .fill(backgroundColor)
    }
    .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
  }

  private var titleBlock: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 0) {
        if let parentTitle = item.parentTitle {
          Text(parentTitle)
            .font(Self.parentTitleFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text(item.title)
          .font(rowTitleFont)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if item.unread && showsPreview == false {
        unreadDot
      }
    }
  }

  @ViewBuilder
  private var avatar: some View {
    if case let .chat(chat) = item.peer {
      SidebarThreadIcon(
        chat: chat,
        size: iconSize,
        shape: isCompact ? .roundedSquare : .circle
      )
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

  private var unreadDot: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: Self.unreadDotSize, height: Self.unreadDotSize)
  }

  private var backgroundColor: Color {
    colorScheme == .dark ? Color(nsColor: .windowBackgroundColor).opacity(0.96) : .white.opacity(0.96)
  }

  private var rowTitleFont: Font {
    item.parentTitle == nil ? Self.titleFont : Self.replyThreadTitleFont
  }
}
