import CoreGraphics

/// Which bottom corner of the bubble carries the tail.
public enum BubbleTailSide: Hashable, Sendable {
  case none
  case leading
  case trailing
}

/// Everything the planner needs to place one message row. Built by the host from its model.
public struct MessageLayoutInput: Hashable, Sendable {
  public enum Body: Hashable, Sendable {
    /// Text inside a bubble.
    case text(MessageText)
    /// One to three emoji drawn large without a bubble.
    case emoji(MessageText)
  }

  public struct Footer: Hashable, Sendable {
    public enum Visibility: Hashable, Sendable {
      case visible
      /// Laid out but drawn transparent, so revealing it later doesn't move anything.
      /// Used while a message streams.
      case reserved
    }

    public var time: MessageText
    /// Delivery status glyph after the time; nil for incoming messages.
    public var statusSize: CGSize?
    public var visibility: Visibility

    public init(time: MessageText, statusSize: CGSize? = nil, visibility: Visibility = .visible) {
      self.time = time
      self.statusSize = statusSize
      self.visibility = visibility
    }
  }

  public struct Reaction: Hashable, Sendable {
    /// Stable identity, the emoji itself.
    public var id: String
    /// Pill size measured by the host.
    public var size: CGSize

    public init(id: String, size: CGSize) {
      self.id = id
      self.size = size
    }
  }

  public enum Avatar: Hashable, Sendable {
    case none
    /// Keeps the avatar column so grouped bubbles line up; nothing is drawn.
    case reserved
    case visible
  }

  public var rowWidth: CGFloat
  public var grid: PixelGrid
  public var layoutDirection: TextDirection
  public var isOutgoing: Bool
  public var isFirstInGroup: Bool
  public var tail: BubbleTailSide
  public var avatar: Avatar
  /// Sender name above the bubble.
  public var name: MessageText?
  public var body: Body
  public var footer: Footer
  public var reactions: [Reaction]
  /// Acknowledgement pill shown before the time.
  public var acknowledgementSize: CGSize?
  public var metrics: MessageLayoutMetrics

  public init(
    rowWidth: CGFloat,
    grid: PixelGrid,
    layoutDirection: TextDirection = .leftToRight,
    isOutgoing: Bool,
    isFirstInGroup: Bool = true,
    tail: BubbleTailSide = .none,
    avatar: Avatar = .none,
    name: MessageText? = nil,
    body: Body,
    footer: Footer,
    reactions: [Reaction] = [],
    acknowledgementSize: CGSize? = nil,
    metrics: MessageLayoutMetrics = .init()
  ) {
    self.rowWidth = rowWidth
    self.grid = grid
    self.layoutDirection = layoutDirection
    self.isOutgoing = isOutgoing
    self.isFirstInGroup = isFirstInGroup
    self.tail = tail
    self.avatar = avatar
    self.name = name
    self.body = body
    self.footer = footer
    self.reactions = reactions
    self.acknowledgementSize = acknowledgementSize
    self.metrics = metrics
  }
}

/// Spacing and sizes. Defaults match the current iOS message view.
public struct MessageLayoutMetrics: Hashable, Sendable {
  public struct Insets: Hashable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
      self.top = top
      self.leading = leading
      self.bottom = bottom
      self.trailing = trailing
    }

    public var horizontal: CGFloat { leading + trailing }
    public var vertical: CGFloat { top + bottom }
  }

  public var rowLeadingInset: CGFloat = 8
  public var rowTrailingInset: CGFloat = 8
  public var groupTopSpacing: CGFloat = 6
  public var followUpTopSpacing: CGFloat = 1
  public var avatarSize: CGFloat = 28
  public var avatarSpacing: CGFloat = 3
  public var maximumBubbleWidthFraction: CGFloat = 0.9
  public var bubbleInsets = Insets(top: 8, leading: 12, bottom: 8, trailing: 12)
  public var cornerRadius: CGFloat = 18
  /// How far the tail reaches past the bubble body.
  public var tailWidth: CGFloat = 7
  public var nameBottomSpacing: CGFloat = 2
  /// Gap between the last text line and an inline time.
  public var inlineTimeSpacing: CGFloat = 6
  /// Gap between text and a time on its own row.
  public var timeRowSpacing: CGFloat = 4
  public var timeStatusSpacing: CGFloat = 2
  public var acknowledgementSpacing: CGFloat = 6
  public var reactionsTopSpacing: CGFloat = 6
  public var reactionSpacing: CGFloat = 4
  public var reactionRowSpacing: CGFloat = 4
  /// Gap between the last reaction and a time on the same row.
  public var reactionTimeSpacing: CGFloat = 6
  public var emojiInsets = Insets(top: 6, leading: 0, bottom: 6, trailing: 0)
  /// Gap between large emoji and the reactions below them.
  public var emojiReactionsSpacing: CGFloat = 8

  public init() {}
}
