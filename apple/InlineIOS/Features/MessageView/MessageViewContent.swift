import Auth
import InlineIOSUI
import InlineKit
import InlineMessageLayout
import struct InlineProtocol.MessageEntity
import InlineTheme
import InlineUI
import TextProcessing
import Translation
import UIKit

/// Where a row sits in the list, as far as its geometry is concerned.
struct MessageRowContext: Equatable {
  var rowWidth: CGFloat
  var isFirstInGroup: Bool
  var isLastInGroup: Bool
  var showsName: Bool
  var avatar: MessageLayoutInput.Avatar
  var theme: IOSThemeSnapshot
  var contentSizeCategory: UIContentSizeCategory
  var displayScale: CGFloat
  var isRightToLeft: Bool

  init(
    rowWidth: CGFloat,
    isFirstInGroup: Bool,
    isLastInGroup: Bool,
    showsName: Bool,
    avatar: MessageLayoutInput.Avatar,
    theme: IOSThemeSnapshot,
    traits: UITraitCollection
  ) {
    self.rowWidth = rowWidth
    self.isFirstInGroup = isFirstInGroup
    self.isLastInGroup = isLastInGroup
    self.showsName = showsName
    self.avatar = avatar
    self.theme = theme
    contentSizeCategory = traits.preferredContentSizeCategory
    // A cell configured before it joins a window can report no scale yet.
    let scale = traits.displayScale > 0 ? traits.displayScale : UITraitCollection.current.displayScale
    displayScale = max(scale, 1)
    isRightToLeft = traits.layoutDirection == .rightToLeft
  }

  var traits: UITraitCollection {
    UITraitCollection { traits in
      traits.preferredContentSizeCategory = contentSizeCategory
      traits.displayScale = displayScale
      traits.layoutDirection = isRightToLeft ? .rightToLeft : .leftToRight
      traits.userInterfaceStyle = theme.variant == .dark ? .dark : .light
    }
  }
}

/// Everything the next message view shows for one message, resolved on the main thread.
/// `input` goes to the planner; the rest styles the planned nodes.
struct MessageViewContent {
  let message: FullMessage
  let context: MessageRowContext
  let input: MessageLayoutInput
  let bubbleColor: UIColor
  let lighting: (top: CGFloat, bottom: CGFloat)?
  let status: MessageSendingStatus?
  let statusColor: UIColor
  let statusSize: CGSize
  let reactions: [MessageReactionPillView.Model]
  /// Forward header, reply, media, file or voice, in order.
  let blocks: [MessageBlock]
  let showsAcknowledgement: Bool
  let accessibilityLabel: String

  var isOutgoing: Bool { message.message.out == true }

  /// Kinds the next view draws today. Everything else keeps the current view until it is built.
  static func supports(_ message: FullMessage, displayMode: MessageDisplayMode) -> Bool {
    let model = message.message
    guard displayMode == .normal,
          !model.isServiceMessage,
          model.isSticker != true,
          // The old file path and rich blocks stay with the current view for now.
          message.file == nil,
          message.attachments.allSatisfy(MessageBlock.supports),
          model.blockContentPayload == nil
    else { return false }
    let hasText = message.displayText?.isEmpty == false
    let hasContent = message.photoInfo != nil || message.videoInfo != nil || message.documentInfo != nil
      || model.hasVoice
    guard hasText || hasContent else { return false }
    // Code blocks need their own block renderer.
    let entities = message.translationEntities ?? model.entities
    return entities?.entities.contains { $0.type == .pre } != true
  }

  /// `footer` is `.reserved` while a message streams: the time keeps its place but stays hidden.
  @MainActor
  static func make(
    _ message: FullMessage,
    context: MessageRowContext,
    footer: MessageLayoutInput.Footer.Visibility = .visible
  ) -> MessageViewContent? {
    // A captionless voice note's display text is its "Voice message" preview; it has no caption.
    let text = message.message.hasVoice && message.message.text?.isEmpty != false ? "" : message.displayText ?? ""
    let traits = context.traits
    let theme = context.theme
    let model = message.message
    let outgoing = model.out == true
    let grid = PixelGrid(scale: context.displayScale)
    let blocks = MessageBlock.blocks(
      for: message,
      context: context,
      maximumContentWidth: maximumContentWidth(context: context, outgoing: outgoing)
    )
    guard !text.isEmpty || !blocks.isEmpty else { return nil }
    let isEmoji = blocks.isEmpty && text.containsOnlyEmojis
    // Captionless media carries its time in a dark pill over its corner, and fills the bubble.
    let hasMedia = blocks.contains { $0.input.isEdgeToEdge }
    let overlaysMedia = hasMedia && text.isEmpty && message.reactions.isEmpty
    let isBareMedia = overlaysMedia && !blocks.contains { $0.kind == .forward || $0.kind == .reply }

    // Large emoji carry their time in a dark pill, like the current view's floating time.
    let textColor: UIColor = outgoing ? .white : theme.incomingText.uiColor
    let secondaryColor: UIColor = if isEmoji || overlaysMedia {
      .white
    } else if outgoing {
      UIColor.white.withAlphaComponent(0.7)
    } else {
      ThemeManager.shared.selected.secondaryTextColor ?? .gray
    }
    let bubbleColor: UIColor = if isEmoji || isBareMedia {
      .clear
    } else if outgoing {
      model.status == .failed ? .systemRed : theme.outgoingBubble.uiColor
    } else {
      theme.incomingBubble.uiColor
    }

    let body = text.isEmpty
      ? MessageText(NSAttributedString())
      : bodyText(text, message: message, isEmoji: isEmoji, textColor: textColor, context: context)
    let time = MessageText(NSAttributedString(
      string: timeFormatter.string(from: model.date),
      attributes: [
        .font: ChatTypography.font(11, style: .caption2, compatibleWith: traits),
        .foregroundColor: secondaryColor,
      ]
    ).coreTextReady(for: traits))
    let statusSize = outgoing ? MessageTimeView.symbolSize(traits: traits) : nil
    let statusColor: UIColor = if isEmoji || overlaysMedia {
      .white
    } else if outgoing {
      UIColor.white.withAlphaComponent(0.7)
    } else {
      model.status == .failed ? .red : .gray
    }

    let name: MessageText? = context.showsName && !outgoing
      ? MessageText(NSAttributedString(
        string: message.from?.firstName ?? "USER",
        attributes: [
          .font: ChatTypography.font(13, weight: .medium, style: .caption1, compatibleWith: traits),
          .foregroundColor: UIColor.secondaryLabel,
        ]
      ).coreTextReady(for: traits))
      : nil

    let reactions = reactionModels(message, outgoing: outgoing, isEmoji: isEmoji, textColor: textColor, context: context)
    let showsAcknowledgement = !message.acknowledgementActors.isEmpty
    let acknowledgementSize = showsAcknowledgement
      ? CGSize(width: message.acknowledgementPillWidth, height: 16)
      : nil

    var metrics = MessageLayoutMetrics()
    metrics.tailWidth = MessageBubbleGeometry.tailWidth(for: .leading)
    metrics.cornerRadius = MessageBubbleGeometry.cornerRadius
    metrics.maximumBubbleWidthFraction = MessageBubbleWidthPolicy.maximumWidthFraction

    let input = MessageLayoutInput(
      rowWidth: context.rowWidth,
      grid: grid,
      layoutDirection: context.isRightToLeft ? .rightToLeft : .leftToRight,
      isOutgoing: outgoing,
      isFirstInGroup: context.isFirstInGroup,
      tail: context.isLastInGroup ? (outgoing ? .trailing : .leading) : .none,
      avatar: outgoing ? .none : context.avatar,
      name: name,
      body: isEmoji ? .emoji(body) : .text(body),
      footer: .init(time: time, statusSize: statusSize, visibility: footer),
      reactions: reactions.map { .init(id: $0.emoji, size: MessageReactionPillView.size(for: $0)) },
      blocks: blocks.map(\.input),
      acknowledgementSize: acknowledgementSize,
      metrics: metrics
    )

    let lighting = outgoing ? theme.outgoingLighting : theme.incomingLighting
    let supportsLighting = !isEmoji && !isBareMedia && model.status != .failed
    return MessageViewContent(
      message: message,
      context: context,
      input: input,
      bubbleColor: bubbleColor,
      lighting: supportsLighting ? (CGFloat(lighting.top), CGFloat(lighting.bottom)) : nil,
      status: outgoing ? model.status : nil,
      statusColor: statusColor,
      statusSize: statusSize ?? .zero,
      reactions: reactions,
      blocks: blocks,
      showsAcknowledgement: showsAcknowledgement,
      accessibilityLabel: ([name?.string] + MessageBlock.accessibilityDescription(of: blocks, message: message)
        + [text.isEmpty ? nil : text, time.string]).compactMap(\.self).joined(separator: ", ")
    )
  }

  // MARK: - Pieces

  /// The widest content a bubble in this row can hold inside its padding.
  private static func maximumContentWidth(context: MessageRowContext, outgoing: Bool) -> CGFloat {
    var metrics = MessageLayoutMetrics()
    metrics.maximumBubbleWidthFraction = MessageBubbleWidthPolicy.maximumWidthFraction
    return MessageLayoutInput(
      rowWidth: context.rowWidth,
      grid: PixelGrid(scale: context.displayScale),
      isOutgoing: outgoing,
      avatar: outgoing ? .none : context.avatar,
      body: .text(MessageText(NSAttributedString())),
      footer: .init(time: MessageText(NSAttributedString())),
      metrics: metrics
    ).maximumContentWidth
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  private static let bodyCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 512
    return cache
  }()

  private static func bodyText(
    _ text: String,
    message: FullMessage,
    isEmoji: Bool,
    textColor: UIColor,
    context: MessageRowContext
  ) -> MessageText {
    let outgoing = message.message.out == true
    let theme = context.theme
    let entities = message.translationEntities ?? message.message.entities
    let key = [
      "\(entities.map { "\($0)" } ?? "")",
      text,
      theme.preset.rawValue,
      theme.variant.rawValue,
      context.contentSizeCategory.rawValue,
      outgoing ? "out" : "in",
      message.message.status == .failed ? "failed" : "",
    ].joined(separator: "-") as NSString
    if let cached = bodyCache.object(forKey: key) {
      return MessageText(cached)
    }

    let traits = context.traits
    let font: UIFont = if isEmoji {
      .systemFont(ofSize: text.count == 1 ? 80 : text.count <= 3 ? 70 : 32)
    } else {
      ChatTypography.font(17, compatibleWith: traits)
    }
    let linkColor: UIColor = outgoing ? .white : theme.primary.uiColor
    let attributed = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: font,
        palette: .init(
          primaryColor: textColor,
          linkColor: linkColor,
          secondaryColor: outgoing ? UIColor.white.withAlphaComponent(0.7) : theme.incomingSecondaryText.uiColor
        ),
        // Inline code has no background for now; see the current view.
        inlineCodeBackgroundColor: .clear
      )
    )
    _ = LinkDetector.shared.applyLinkStyling(to: attributed, linkColor: linkColor)
    let ready = attributed.coreTextReady(for: traits)
    bodyCache.setObject(ready, forKey: key)
    return MessageText(ready)
  }

  private static func reactionModels(
    _ message: FullMessage,
    outgoing: Bool,
    isEmoji: Bool,
    textColor: UIColor,
    context: MessageRowContext
  ) -> [MessageReactionPillView.Model] {
    let groups = message.groupedReactions
    guard !groups.isEmpty else { return [] }
    let traits = context.traits
    let grid = PixelGrid(scale: context.displayScale)
    let currentUserID = Auth.shared.getCurrentUserId() ?? 0
    let selected = ThemeManager.shared.selected
    let emojiFont = UIFont.systemFont(ofSize: 20, weight: .medium)
    let countFont = ChatTypography.font(13, weight: .medium, style: .caption1, compatibleWith: traits)
    // Without a bubble behind them, outgoing pills use darkened incoming colors to stay visible.
    let transparentBase = context.theme.incomingBubble.uiColor.resolvedColor(with: traits)

    return groups.map { group in
      let byCurrentUser = group.reactions.contains { $0.reaction.userId == currentUserID }
      let avatars = group.reactions.count <= MessageReactionPillView.Metrics.maximumAvatars
        ? group.reactions.compactMap(\.userInfo)
        : []
      let background: UIColor = if outgoing, isEmoji {
        transparentBase.darkened(by: byCurrentUser ? 0.08 : 0.04)
      } else if byCurrentUser {
        (outgoing ? selected.reactionOutgoingPrimary : selected.reactionIncomingPrimary) ?? .systemFill
      } else {
        (outgoing ? selected.reactionOutgoingSecoundry : selected.reactionIncomingSecoundry) ?? .secondarySystemFill
      }
      let emojiLayout = TextLayouter.layout(
        MessageText(NSAttributedString(string: group.emoji, attributes: [.font: emojiFont])),
        maximumWidth: 200,
        grid: grid
      )
      let countLayout = avatars.isEmpty
        ? TextLayouter.layout(
          MessageText(NSAttributedString(
            string: "\(group.reactions.count)",
            attributes: [.font: countFont, .foregroundColor: isEmoji ? UIColor.label : textColor]
          ).coreTextReady(for: traits)),
          maximumWidth: 200,
          grid: grid
        )
        : nil
      return MessageReactionPillView.Model(
        emoji: group.emoji,
        count: group.reactions.count,
        byCurrentUser: byCurrentUser,
        avatars: avatars,
        users: group.reactions.map {
          ReactionUser(userId: $0.reaction.userId, userInfo: $0.userInfo, reactedAt: $0.reaction.date)
        },
        emojiLayout: emojiLayout,
        countLayout: countLayout,
        background: background,
        pressedBackground: background.withAlphaComponent(0.82)
      )
    }
  }
}

private extension UIColor {
  func darkened(by amount: CGFloat) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
    return UIColor(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount), alpha: alpha)
  }
}

extension BubbleTailSide {
  /// The physical side the bubble path draws, after right-to-left mirroring.
  func physical(isRightToLeft: Bool) -> MessageBubbleTailSide {
    switch self {
    case .none: .none
    case .leading: isRightToLeft ? .trailing : .leading
    case .trailing: isRightToLeft ? .leading : .trailing
    }
  }
}

extension MessageMotion {
  /// Runs `changes` with this motion. Every node a view sets inside shares the one animation.
  func animate(_ changes: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
    switch self {
    case .immediate:
      UIView.performWithoutAnimation(changes)
      completion?(true)
    case let .easeInOut(duration):
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
        animations: changes,
        completion: completion
      )
    case let .spring(duration, bounce):
      UIView.animate(
        springDuration: duration,
        bounce: bounce,
        initialSpringVelocity: 0,
        delay: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: changes,
        completion: completion
      )
    }
  }
}
