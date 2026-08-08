import InlineKit
import InlineUI
import SwiftUI
import Translation

struct ExperimentalChatListRow: View, @MainActor Equatable {
  let item: ChatListItemSnapshot
  let layoutMode: ChatListLayoutMode
  let showsPinnedIndicator: Bool
  let showsActivityTime: Bool
  @State private var showsTranslatedPreview: Bool

  init(
    item: ChatListItemSnapshot,
    layoutMode: ChatListLayoutMode,
    showsPinnedIndicator: Bool = true,
    showsActivityTime: Bool = false
  ) {
    self.item = item
    self.layoutMode = layoutMode
    self.showsPinnedIndicator = showsPinnedIndicator
    self.showsActivityTime = showsActivityTime
    _showsTranslatedPreview = State(
      initialValue: TranslationState.shared.isTranslationEnabled(for: item.peer)
    )
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item
      && lhs.layoutMode == rhs.layoutMode
      && lhs.showsPinnedIndicator == rhs.showsPinnedIndicator
      && lhs.showsActivityTime == rhs.showsActivityTime
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if item.unreadMark, item.unreadCount == 0 {
        dotUnreadIndicator
      }

      HStack(alignment: .center, spacing: metrics.horizontalSpacing) {
        identity

        VStack(alignment: .leading, spacing: metrics.textSpacing) {
          titleLine

          if metrics.previewLines > 0,
             resolvedPreviewText != nil || showsNumberedUnread {
            previewLine
          }
        }
      }
      .padding(.leading, unreadGutter)
    }
    .frame(minHeight: metrics.minimumHeight)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .onReceive(TranslationState.shared.subject) { event in
      let (peer, isEnabled) = event
      guard peer == item.peer else { return }
      guard showsTranslatedPreview != isEnabled else { return }
      showsTranslatedPreview = isEnabled
    }
  }

  private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(item.title)
        .font(titleFont)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)

      Spacer(minLength: 4)

      if item.isPinned, showsPinnedIndicator {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }

      if showsActivityTime,
         layoutMode != .compact,
         let timestampText = item.timestampText {
        Text(timestampText)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }

      if layoutMode == .compact {
        numberedUnreadIndicator
      }
    }
  }

  private var previewLine: some View {
    HStack(alignment: .center, spacing: 8) {
      if let previewText = resolvedPreviewText {
        ChatListPreviewText(
          senderName: item.previewSenderName,
          text: previewText
        )
          .font(.subheadline)
          .lineLimit(metrics.previewLines)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Color.clear
          .frame(maxWidth: .infinity, minHeight: 1)
      }

      numberedUnreadIndicator
    }
  }

  @ViewBuilder
  private var identity: some View {
    switch item.identity {
    case let .user(descriptor):
      UserAvatar(
        userID: descriptor.userID,
        firstName: descriptor.firstName,
        lastName: descriptor.lastName,
        email: descriptor.email,
        username: descriptor.username,
        stableAvatarIdentity: descriptor.stableAvatarIdentity,
        remoteURL: descriptor.remoteURL,
        localURL: descriptor.localURL,
        size: metrics.avatarSize
      )
        .equatable()
    case let .thread(descriptor):
      ThreadIconView(
        ThreadIconDescriptor(
          emoji: descriptor.emoji,
          title: descriptor.title,
          isReplyThread: descriptor.isReplyThread,
          accessibilityLabel: descriptor.title
        ),
        size: layoutMode == .compact
          ? .compact(metrics.avatarSize * 0.9)
          : .large(metrics.avatarSize),
        shape: layoutMode == .compact ? .none : .circle,
        symbolColor: layoutMode == .compact ? .primary : .secondary
      )
      .equatable()
      .frame(width: metrics.avatarSize, height: metrics.avatarSize)
    case nil:
      ThreadIconView(
        ThreadIconDescriptor(emoji: nil, title: item.title),
        size: layoutMode == .compact
          ? .compact(metrics.avatarSize * 0.9)
          : .large(metrics.avatarSize),
        shape: layoutMode == .compact ? .none : .circle,
        symbolColor: layoutMode == .compact ? .primary : .secondary
      )
      .equatable()
      .frame(width: metrics.avatarSize, height: metrics.avatarSize)
    }
  }

  @ViewBuilder
  private var dotUnreadIndicator: some View {
    Group {
      if item.unreadMark, item.unreadCount == 0 {
        Circle()
          .fill(item.isProminent ? Color.accentColor : Color.secondary)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private var numberedUnreadIndicator: some View {
    if item.unreadCount > 0 {
      Text(item.unreadCount > 99 ? "99+" : "\(item.unreadCount)")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(minWidth: 20, minHeight: 20)
        .background(item.isProminent ? Color.accentColor : Color.secondary, in: Capsule())
        .accessibilityLabel("\(item.unreadCount) unread messages")
    }
  }

  private var showsNumberedUnread: Bool {
    item.unreadCount > 0
  }

  private var unreadGutter: CGFloat {
    11
  }

  private var resolvedPreviewText: String? {
    let source = if showsTranslatedPreview {
      item.translatedPreviewText ?? item.previewText
    } else {
      item.previewText
    }
    let preview = source?.trimmingCharacters(in: .whitespacesAndNewlines)
    return preview?.isEmpty == false ? preview : nil
  }

  private var accessibilityLabel: String {
    var parts = [item.title]
    if let resolvedPreviewText {
      if let senderName = item.previewSenderName, senderName.isEmpty == false {
        parts.append("\(senderName): \(resolvedPreviewText)")
      } else {
        parts.append(resolvedPreviewText)
      }
    }
    if showsActivityTime,
       layoutMode != .compact,
       let timestampText = item.timestampText {
      parts.append(timestampText)
    }
    if item.isUnread {
      parts.append(item.unreadCount > 0 ? "\(item.unreadCount) unread" : "unread")
    }
    if item.isPinned, showsPinnedIndicator {
      parts.append("pinned")
    }
    return parts.joined(separator: ", ")
  }

  private var metrics: Metrics {
    switch layoutMode {
    case .compact:
      Metrics(avatarSize: 34, minimumHeight: 35, horizontalSpacing: 10, textSpacing: 0, previewLines: 0)
    case .standard:
      Metrics(avatarSize: 44, minimumHeight: 52, horizontalSpacing: 10, textSpacing: 2, previewLines: 1)
    case .large:
      Metrics(avatarSize: 56, minimumHeight: 66, horizontalSpacing: 12, textSpacing: 2, previewLines: 2)
    }
  }

  private var titleFont: Font {
    switch layoutMode {
    case .compact:
      .body.weight(item.isUnread ? .semibold : .medium)
    case .standard, .large:
      .callout.weight(item.isUnread ? .semibold : .medium)
    }
  }
}

private struct ChatListPreviewText: View {
  let senderName: String?
  let text: String

  var body: some View {
    if let senderName, senderName.isEmpty == false {
      Text("\(Text(senderName).foregroundStyle(.primary)): \(Text(text).foregroundStyle(.secondary))")
    } else {
      Text(text)
        .foregroundStyle(.secondary)
    }
  }
}

private struct Metrics {
  let avatarSize: CGFloat
  let minimumHeight: CGFloat
  let horizontalSpacing: CGFloat
  let textSpacing: CGFloat
  let previewLines: Int
}
