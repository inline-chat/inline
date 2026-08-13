import InlineKit
import InlineUI
import SwiftUI
import Translation

struct ExperimentalChatListRow: View, @MainActor Equatable {
  let item: ChatListItemSnapshot
  let layoutMode: ChatListLayoutMode
  let showsPinnedIndicator: Bool
  let showsActivityTime: Bool
  let unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle
  let leadingInset: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutDirection) private var layoutDirection
  @ScaledMetric(relativeTo: .footnote) private var timestampWidth: CGFloat = 54
  @ScaledMetric(relativeTo: .footnote) private var timestampBaselineLift: CGFloat = 2
  @ScaledMetric(relativeTo: .caption) private var unreadBadgeWidth: CGFloat = 24
  @ScaledMetric(relativeTo: .caption) private var unreadBadgeHeight: CGFloat = 19
  @State private var showsTranslatedPreview: Bool

  init(
    item: ChatListItemSnapshot,
    layoutMode: ChatListLayoutMode,
    showsPinnedIndicator: Bool = true,
    showsActivityTime: Bool = false,
    unreadBadgeStyle: ExperimentalHomeUnreadBadgeStyle = .defaultValue,
    leadingInset: CGFloat
  ) {
    self.item = item
    self.layoutMode = layoutMode
    self.showsPinnedIndicator = showsPinnedIndicator
    self.showsActivityTime = showsActivityTime
    self.unreadBadgeStyle = unreadBadgeStyle
    self.leadingInset = leadingInset
    _showsTranslatedPreview = State(
      initialValue: TranslationState.shared.isTranslationEnabled(for: item.peer)
    )
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item
      && lhs.layoutMode == rhs.layoutMode
      && lhs.showsPinnedIndicator == rhs.showsPinnedIndicator
      && lhs.showsActivityTime == rhs.showsActivityTime
      && lhs.unreadBadgeStyle == rhs.unreadBadgeStyle
      && lhs.leadingInset == rhs.leadingInset
  }

  var body: some View {
    ZStack(alignment: .leading) {
      dotUnreadIndicator

      HStack(alignment: .center, spacing: metrics.horizontalSpacing) {
        identity

        VStack(alignment: .leading, spacing: metrics.textSpacing) {
          titleLine

          if metrics.previewLines > 0 {
            previewLine
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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
        .foregroundStyle(titleColor)
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

      if layoutMode == .compact {
        ComposeActionCompactAccessory(peer: item.peer)

        if showsNumberedUnread {
          unreadBadge
            .transition(unreadTransition)
        }
      } else if let timestampText = displayedTimestampText {
        Text(timestampText)
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: timestampWidth, alignment: .trailing)
          .alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[.firstTextBaseline] + timestampBaselineLift
          }
      }
    }
    .animation(unreadAnimation, value: showsNumberedUnread)
  }

  private var previewLine: some View {
    HStack(alignment: .bottom, spacing: 8) {
      previewContent
        .frame(maxWidth: .infinity, alignment: .leading)

      if showsNumberedUnread {
        unreadBadge
          .transition(unreadTransition)
      }
    }
    .animation(unreadAnimation, value: showsNumberedUnread)
  }

  @ViewBuilder
  private var previewContent: some View {
    ChatListComposeActivityPreview(
      peer: item.peer,
      senderName: resolvedPreviewSenderName,
      text: resolvedPreviewText,
      layoutMode: layoutMode,
      previewLines: metrics.previewLines
    )
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
        .frame(width: metrics.identityContainerSize, height: metrics.identityContainerSize)
    case let .thread(descriptor):
      ThreadIconView(
        ThreadIconDescriptor(
          emoji: descriptor.emoji,
          title: descriptor.title,
          isReplyThread: descriptor.isReplyThread,
          accessibilityLabel: descriptor.title
        ),
        size: metrics.threadIconSize,
        shape: metrics.threadIconShape,
        symbolColor: metrics.threadSymbolColor,
        contentScaleMultiplier: metrics.iconContentScale
      )
      .equatable()
      .opacity(metrics.iconOpacity)
      .frame(width: metrics.identityContainerSize, height: metrics.identityContainerSize)
    case nil:
      ThreadIconView(
        ThreadIconDescriptor(emoji: nil, title: item.title),
        size: metrics.threadIconSize,
        shape: metrics.threadIconShape,
        symbolColor: metrics.threadSymbolColor,
        contentScaleMultiplier: metrics.iconContentScale
      )
      .equatable()
      .opacity(metrics.iconOpacity)
      .frame(width: metrics.identityContainerSize, height: metrics.identityContainerSize)
    }
  }

  @ViewBuilder
  private var dotUnreadIndicator: some View {
    ZStack {
      if showsDotUnread {
        Circle()
          .fill(item.isProminent ? Color.accentColor : Color.secondary)
          .frame(width: 8, height: 8)
          .offset(x: dotUnreadOffset)
          .transition(unreadTransition)
          .accessibilityHidden(true)
      }
    }
    .animation(unreadAnimation, value: showsDotUnread)
  }

  private var unreadBadge: some View {
    Text(displayedUnreadText)
      .font(.caption.weight(.semibold).monospacedDigit())
      .foregroundStyle(item.isProminent ? Color.white : Color(.systemBackground))
      .lineLimit(1)
      .minimumScaleFactor(0.76)
      .frame(width: unreadBadgeWidth, height: unreadBadgeHeight)
      .background(
        item.isProminent ? Color.accentColor : Color(.systemGray2),
        in: Capsule()
      )
      .contentTransition(.numericText(value: Double(min(displayedUnreadCount, 99))))
      .animation(unreadAnimation, value: displayedUnreadCount)
      .accessibilityLabel(
        item.unreadCount > 0 ? "\(item.unreadCount) unread messages" : "Marked unread"
      )
  }

  private var showsDotUnread: Bool {
    unreadBadgeStyle == .dot && item.isUnread
  }

  private var showsNumberedUnread: Bool {
    unreadBadgeStyle == .numbered && item.isUnread
  }

  private var displayedUnreadCount: Int {
    max(item.unreadCount, 1)
  }

  private var displayedUnreadText: String {
    displayedUnreadCount > 99 ? "99+" : "\(displayedUnreadCount)"
  }

  private var dotUnreadOffset: CGFloat {
    let magnitude = min(10, leadingInset / 2)
    return layoutDirection == .leftToRight ? -magnitude : magnitude
  }

  private var unreadAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.18)
  }

  private var unreadTransition: AnyTransition {
    reduceMotion ? .opacity : .scale(scale: 0.88).combined(with: .opacity)
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

  private var resolvedPreviewSenderName: String? {
    let sender = item.previewSenderName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return sender?.isEmpty == false ? sender : nil
  }

  private var displayedTimestampText: String? {
    guard showsActivityTime,
          layoutMode != .compact,
          resolvedPreviewText != nil
    else { return nil }

    return item.timestampText
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
    if let timestampText = displayedTimestampText {
      parts.append(timestampText)
    }
    if item.isUnread {
      parts.append(item.unreadCount > 0 ? "\(item.unreadCount) unread" : "unread")
    }
    if item.isPinned {
      parts.append("pinned")
    }
    return parts.joined(separator: ", ")
  }

  private var metrics: Metrics {
    switch layoutMode {
    case .compact:
      Metrics(
        avatarSize: 30,
        identityContainerSize: 32,
        threadIconSize: .regular(32),
        threadIconShape: .none,
        threadSymbolColor: .mutedPrimary,
        iconContentScale: 1.15,
        iconOpacity: 1,
        minimumHeight: 44,
        horizontalSpacing: 12,
        textSpacing: 0,
        previewLines: 0
      )
    case .standard:
      Metrics(
        avatarSize: 44,
        identityContainerSize: 44,
        threadIconSize: .large(44),
        threadIconShape: .circle,
        threadSymbolColor: .mutedPrimary,
        iconContentScale: 0.96,
        iconOpacity: 1,
        minimumHeight: 52,
        horizontalSpacing: 10,
        textSpacing: 0,
        previewLines: 1
      )
    case .large:
      Metrics(
        avatarSize: 56,
        identityContainerSize: 56,
        threadIconSize: .large(56),
        threadIconShape: .circle,
        threadSymbolColor: .primary,
        iconContentScale: 0.88,
        iconOpacity: 0.84,
        minimumHeight: 72,
        horizontalSpacing: 12,
        textSpacing: 0,
        previewLines: 2
      )
    }
  }

  private var titleColor: Color {
    layoutMode == .compact ? Color.primary.opacity(0.88) : .primary
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

@MainActor
private struct ChatListComposeActivityPreview: View {
  let peer: Peer
  let senderName: String?
  let text: String?
  let layoutMode: ChatListLayoutMode
  let previewLines: Int

  @ScaledMetric(relativeTo: .subheadline) private var singleLineHeight: CGFloat = 18
  @ScaledMetric(relativeTo: .subheadline) private var largePreviewHeight: CGFloat = 38
  @ScaledMetric(relativeTo: .subheadline) private var largeMessageFontSize: CGFloat = 14
  @State private var activityState: ComposeActionActivityState

  init(
    peer: Peer,
    senderName: String?,
    text: String?,
    layoutMode: ChatListLayoutMode,
    previewLines: Int
  ) {
    self.peer = peer
    self.senderName = senderName
    self.text = text
    self.layoutMode = layoutMode
    self.previewLines = previewLines
    _activityState = State(initialValue: ComposeActions.shared.activityState(for: peer))
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if let presentation = activityState.presentation {
        HStack(alignment: .center, spacing: 5) {
          ComposeActionActivityIndicator(
            action: presentation.action,
            color: .accentColor
          )

          Text(presentation.text)
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
        }
        .id("activity-\(presentation.action.rawValue)-\(presentation.text)")
        .transition(Self.swapTransition)
      } else {
        preview
          .id("preview")
          .transition(Self.swapTransition)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: previewHeight, alignment: previewAlignment)
    .clipped()
    .animation(.easeInOut(duration: 0.18), value: activityState.presentation)
  }

  @ViewBuilder
  private var preview: some View {
    if let text {
      if layoutMode == .large, let senderName {
        VStack(alignment: .leading, spacing: 0) {
          Text(senderName)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.primary.opacity(0.84))
            .lineLimit(1)

          Text(text)
            .font(.system(size: largeMessageFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .truncationMode(.tail)
      } else {
        ChatListPreviewText(senderName: senderName, text: text)
          .font(.subheadline)
          .lineLimit(previewLines)
          .truncationMode(.tail)
      }
    } else {
      Color.clear
    }
  }

  private var previewHeight: CGFloat {
    layoutMode == .large ? largePreviewHeight : singleLineHeight
  }

  private var previewAlignment: Alignment {
    layoutMode == .large ? .topLeading : .leading
  }

  private static var swapTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 2)),
      removal: .opacity.combined(with: .offset(y: -2))
    )
  }
}

private struct ChatListPreviewText: View {
  let senderName: String?
  let text: String

  var body: some View {
    if let senderName, senderName.isEmpty == false {
      Text(
        "\(Text(senderName).fontWeight(.medium).foregroundStyle(Color.primary.opacity(0.80))): \(Text(text).foregroundStyle(.secondary))"
      )
    } else {
      Text(text)
        .foregroundStyle(.secondary)
    }
  }
}

private struct Metrics {
  let avatarSize: CGFloat
  let identityContainerSize: CGFloat
  let threadIconSize: ThreadIconSize
  let threadIconShape: ThreadIconShape
  let threadSymbolColor: ThreadIconSymbolColor
  let iconContentScale: CGFloat
  let iconOpacity: Double
  let minimumHeight: CGFloat
  let horizontalSpacing: CGFloat
  let textSpacing: CGFloat
  let previewLines: Int
}
