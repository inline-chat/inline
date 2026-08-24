import AppKit
import InlineKit
import MacTheme
import SwiftUI

struct OnboardingMessageStylePreview: View {
  static let size = CGSize(width: 500, height: 230)

  @Environment(\.colorScheme) private var colorScheme

  let style: MessageRenderStyle
  let currentUserInfo: UserInfo

  var body: some View {
    let conversation = OnboardingMessagePreviewFactory.make(currentUserInfo: currentUserInfo)

    VStack(spacing: 0) {
      ForEach(conversation.rows) { row in
        OnboardingProductionMessageRow(
          message: row.message,
          width: Self.size.width,
          style: style,
          isDarkMode: colorScheme == .dark,
          isFirstMessage: row.isFirstMessage,
          isLastMessage: row.isLastMessage
        )
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 10)
    .frame(width: Self.size.width, height: Self.size.height)
    .background(Color(nsColor: Theme.windowContentBackgroundColor).opacity(0.5))
    .clipped()
  }
}

private struct OnboardingMessagePreviewConversation {
  let rows: [OnboardingMessagePreviewRow]
}

private struct OnboardingMessagePreviewRow: Identifiable {
  let message: FullMessage
  let isFirstMessage: Bool
  let isLastMessage: Bool

  var id: Int64 { message.id }
}

private enum OnboardingMessagePreviewFactory {
  private static let chatID: Int64 = -9_100
  private static let fixtureDate = Date(timeIntervalSince1970: 1_755_000_000)
  private static let incomingUserInfo = UserInfo(user: User(
    id: -9_001,
    email: "mo@example.com",
    firstName: "Mo",
    username: "mo"
  ))

  static func make(currentUserInfo: UserInfo) -> OnboardingMessagePreviewConversation {
    let welcome = makeMessage(
      id: -9_101,
      senderInfo: incomingUserInfo,
      text: "Want to review the launch notes together?",
      date: fixtureDate,
      outgoing: false
    )
    let choice = makeMessage(
      id: -9_102,
      senderInfo: currentUserInfo,
      text: "Yes — give me a minute to finish this.",
      date: fixtureDate.addingTimeInterval(60),
      outgoing: true
    )
    let reply = makeMessage(
      id: -9_103,
      senderInfo: incomingUserInfo,
      text: "Perfect, I'll send them over.",
      date: fixtureDate.addingTimeInterval(120),
      outgoing: false,
      repliedTo: choice
    )

    return OnboardingMessagePreviewConversation(
      rows: [
        OnboardingMessagePreviewRow(
          message: welcome,
          isFirstMessage: true,
          isLastMessage: false
        ),
        OnboardingMessagePreviewRow(
          message: choice,
          isFirstMessage: false,
          isLastMessage: false
        ),
        OnboardingMessagePreviewRow(
          message: reply,
          isFirstMessage: false,
          isLastMessage: true
        ),
      ]
    )
  }

  private static func makeMessage(
    id: Int64,
    senderInfo: UserInfo,
    text: String,
    date: Date,
    outgoing: Bool,
    repliedTo: FullMessage? = nil
  ) -> FullMessage {
    var message = Message(
      messageId: id,
      fromId: senderInfo.user.id,
      date: date,
      text: text,
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID,
      out: outgoing,
      status: outgoing ? .sent : nil,
      repliedToMessageId: repliedTo?.message.messageId
    )
    message.globalId = id

    return FullMessage(
      senderInfo: senderInfo,
      message: message,
      reactions: [],
      repliedToMessage: repliedTo.map {
        EmbeddedMessage(
          message: $0.message,
          senderInfo: $0.senderInfo
        )
      },
      attachments: []
    )
  }
}

private struct OnboardingProductionMessageRow: NSViewRepresentable {
  let message: FullMessage
  let width: CGFloat
  let style: MessageRenderStyle
  let isDarkMode: Bool
  let isFirstMessage: Bool
  let isLastMessage: Bool

  func makeNSView(context _: Context) -> MessageTableCell {
    let cell = OnboardingMessagePreviewCell(frame: .zero)
    configure(cell, width: width)
    return cell
  }

  func updateNSView(_ cell: MessageTableCell, context _: Context) {
    configure(cell, width: width)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView _: MessageTableCell,
    context _: Context
  ) -> CGSize? {
    let resolvedWidth = proposal.width ?? width
    return CGSize(width: resolvedWidth, height: makeProps(width: resolvedWidth).layout.totalHeight)
  }

  private func configure(_ cell: MessageTableCell, width: CGFloat) {
    let props = makeProps(width: width)
    cell.setScrollState(.idle)
    cell.configure(with: message, props: props, animate: false)

    if let previewCell = cell as? OnboardingMessagePreviewCell {
      previewCell.configurePreviewInlineTime(message: message, props: props)
      previewCell.configurePreviewReplyAppearance(style: style)
      previewCell.configurePreviewBubbleAppearance(
        style: style,
        outgoing: message.message.out == true,
        isDarkMode: isDarkMode
      )
      previewCell.configurePreviewTimeAppearance(
        style: style,
        outgoing: message.message.out == true,
        isDarkMode: isDarkMode
      )
    }
  }

  private func makeProps(width: CGFloat) -> MessageViewProps {
    let inputProps = MessageViewInputProps(
      firstInGroup: true,
      lastInGroup: true,
      startsAfterDaySeparator: false,
      isLastMessage: isLastMessage,
      isFirstMessage: isFirstMessage,
      isDM: false,
      isRtl: false,
      translated: false,
      renderStyle: style
    )
    var layout = MessageSizeCalculator.shared.calculateSize(
      for: message,
      with: inputProps,
      tableWidth: width
    ).3

    if style == .minimal, var avatar = layout.avatar {
      avatar.spacing.left = Theme.messageSidePadding
      layout.avatar = avatar
    }

    return MessageViewProps(
      firstInGroup: inputProps.firstInGroup,
      lastInGroup: inputProps.lastInGroup,
      startsAfterDaySeparator: inputProps.startsAfterDaySeparator,
      isLastMessage: inputProps.isLastMessage,
      isFirstMessage: inputProps.isFirstMessage,
      isRtl: inputProps.isRtl,
      isDM: inputProps.isDM,
      renderStyle: style,
      index: nil,
      translated: false,
      usesAvatarOverlay: false,
      layout: layout
    )
  }
}

private final class OnboardingMessagePreviewCell: MessageTableCell {
  private var previewInlineTimeView: MessageTimeAndState?
  private var previewInlineTimeConstraints: [NSLayoutConstraint] = []
  private weak var previewReplyBarView: NSView?
  private var previewReplyBarOriginalConstraints: [NSLayoutConstraint] = []
  private var previewReplyBarTextConstraints: [NSLayoutConstraint] = []

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  func configurePreviewInlineTime(message: FullMessage, props: MessageViewProps) {
    clearPreviewInlineTime()

    guard props.renderStyle == .minimal,
          props.layout.singleLine,
          let text = props.layout.text,
          let time = props.layout.time
    else { return }

    let timeView = MessageTimeAndState(
      fullMessage: message,
      overlay: false,
      contentAlignment: .left
    )
    timeView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(timeView)

    let layout = props.layout
    let reservedAvatarSlotWidth =
      MessageSizeCalculator.minimalContentLeadingInset + MessageSizeCalculator.minimalAvatarSize +
      Theme.messageHorizontalStackSpacing
    let contentLeading = if let avatar = layout.avatar {
      avatar.spacing.left + avatar.size.width + avatar.spacing.right
    } else {
      reservedAvatarSlotWidth
    }
    let nameHeight = layout.name.map { $0.size.height + $0.spacing.bottom } ?? 0
    let textTop = layout.wrapper.spacing.top + nameHeight + layout.textContentViewTop
    let timeTop = textTop + max(0, (text.size.height - time.size.height) / 2)

    previewInlineTimeConstraints = [
      timeView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: contentLeading + text.spacing.left + text.size.width + time.spacing.left
      ),
      timeView.topAnchor.constraint(equalTo: topAnchor, constant: timeTop),
      timeView.widthAnchor.constraint(equalToConstant: time.size.width),
      timeView.heightAnchor.constraint(equalToConstant: time.size.height),
    ]
    NSLayoutConstraint.activate(previewInlineTimeConstraints)
    previewInlineTimeView = timeView
  }

  func configurePreviewReplyAppearance(style: MessageRenderStyle) {
    restorePreviewReplyBarConstraints()

    guard let replyView = firstDescendant(of: EmbeddedMessageView.self) else { return }

    switch style {
      case .minimal:
        replyView.layer?.cornerRadius = 0
        replyView.layer?.backgroundColor = NSColor.clear.cgColor
        configureMinimalPreviewReplyBar(in: replyView)
      case .bubble:
        guard let barColor = replyView.subviews.compactMap({ $0.layer?.backgroundColor }).first,
              let senderColor = NSColor(cgColor: barColor)
        else { return }
        replyView.layer?.backgroundColor = senderColor.withAlphaComponent(0.1).cgColor
    }
  }

  private func configureMinimalPreviewReplyBar(in replyView: EmbeddedMessageView) {
    guard let barView = replyView.subviews.first(where: { $0.layer?.backgroundColor != nil }),
          let nameLabel = replyView.subviews.compactMap({ $0 as? NSTextField }).first,
          let messageLabel = replyView.subviews.compactMap({ $0 as? NSTextField }).last
    else { return }

    let originalConstraints = replyView.constraints.filter { constraint in
      guard (constraint.firstItem as? NSView) === barView else { return false }
      return constraint.firstAttribute == .top || constraint.firstAttribute == .bottom
    }
    guard !originalConstraints.isEmpty else { return }

    NSLayoutConstraint.deactivate(originalConstraints)
    let textConstraints = [
      barView.topAnchor.constraint(equalTo: nameLabel.topAnchor),
      barView.bottomAnchor.constraint(equalTo: messageLabel.bottomAnchor),
    ]
    NSLayoutConstraint.activate(textConstraints)

    previewReplyBarView = barView
    previewReplyBarOriginalConstraints = originalConstraints
    previewReplyBarTextConstraints = textConstraints
  }

  private func restorePreviewReplyBarConstraints() {
    NSLayoutConstraint.deactivate(previewReplyBarTextConstraints)
    if previewReplyBarView?.superview != nil {
      NSLayoutConstraint.activate(previewReplyBarOriginalConstraints)
    }
    previewReplyBarView = nil
    previewReplyBarOriginalConstraints.removeAll()
    previewReplyBarTextConstraints.removeAll()
  }

  fileprivate func configurePreviewBubbleAppearance(
    style: MessageRenderStyle,
    outgoing: Bool,
    isDarkMode: Bool
  ) {
    guard style == .bubble, !outgoing,
          let bubbleView = firstDescendant(of: MessageBubbleBackgroundView.self)
    else { return }

    let gray = NSColor(calibratedWhite: isDarkMode ? 0.18 : 0.86, alpha: 1)
    bubbleView.backgroundColor = gray
    firstDescendant(of: MessageBubbleTailView.self)?.configure(side: .leading, color: gray)
  }

  fileprivate func configurePreviewTimeAppearance(
    style: MessageRenderStyle,
    outgoing: Bool,
    isDarkMode: Bool
  ) {
    let color: NSColor = if isDarkMode {
      .white.withAlphaComponent(0.88)
    } else if style == .bubble, outgoing {
      .white.withAlphaComponent(0.7)
    } else {
      .tertiaryLabelColor
    }

    for timeView in descendants(of: MessageTimeAndState.self) {
      for textLayer in timeView.layer?.sublayers?.compactMap({ $0 as? CATextLayer }) ?? [] {
        textLayer.foregroundColor = color.cgColor
        if let attributedString = textLayer.string as? NSAttributedString {
          let recoloredString = NSMutableAttributedString(attributedString: attributedString)
          recoloredString.addAttribute(
            .foregroundColor,
            value: color,
            range: NSRange(location: 0, length: recoloredString.length)
          )
          textLayer.string = recoloredString
        }
      }
    }
  }

  private func clearPreviewInlineTime() {
    NSLayoutConstraint.deactivate(previewInlineTimeConstraints)
    previewInlineTimeConstraints.removeAll()
    previewInlineTimeView?.removeFromSuperview()
    previewInlineTimeView = nil
  }

  private func firstDescendant<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
    for subview in subviews {
      if let match = subview as? ViewType {
        return match
      }
      if let match = firstDescendant(of: type, in: subview) {
        return match
      }
    }
    return nil
  }

  private func descendants<ViewType: NSView>(of type: ViewType.Type) -> [ViewType] {
    descendants(of: type, in: self)
  }

  private func descendants<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
  ) -> [ViewType] {
    root.subviews.flatMap { subview in
      let match = (subview as? ViewType).map { [$0] } ?? []
      return match + descendants(of: type, in: subview)
    }
  }

  private func firstDescendant<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
  ) -> ViewType? {
    for subview in root.subviews {
      if let match = subview as? ViewType {
        return match
      }
      if let match = firstDescendant(of: type, in: subview) {
        return match
      }
    }
    return nil
  }
}
