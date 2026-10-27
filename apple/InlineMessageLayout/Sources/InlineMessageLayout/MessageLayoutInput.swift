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
    /// Paragraphs, lists, quotes, code, tables and more, laid out by `RichLayoutPlanner`.
    case rich([RichBlock])
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

  /// Content stacked in the bubble with the text: a quoted reply, a forward header, a file, a
  /// voice note, media, a link preview, buttons. The host draws it; the planner only places it.
  public struct Block: Hashable, Sendable {
    public enum Position: Hashable, Sendable {
      case aboveText
      case belowText
      /// Under the bubble, outside it, on the bubble's side of the row: bot buttons.
      case belowBubble
    }

    public enum Width: Hashable, Sendable {
      /// The block keeps this width; the bubble widens to fit it.
      case fixed(CGFloat)
      /// The block asks for `preferred`, never takes less than `minimum`, and stretches to the
      /// bubble's content width.
      case flexible(preferred: CGFloat, minimum: CGFloat)
    }

    /// Stable identity, so the same block animates between layouts.
    public var id: String
    public var position: Position
    public var width: Width
    public var height: CGFloat
    /// Media drawn to the bubble's edges instead of inside its padding. Its fixed width sets the
    /// bubble's width, and a caption wraps to it. Only the first such block is placed this way.
    public var isEdgeToEdge: Bool

    public init(id: String, position: Position, width: Width, height: CGFloat, isEdgeToEdge: Bool = false) {
      self.id = id
      self.position = position
      self.width = width
      self.height = height
      self.isEdgeToEdge = isEdgeToEdge
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
  /// In order; above-text blocks come before the text, below-text blocks after it.
  public var blocks: [Block]
  /// Acknowledgement pill shown before the time.
  public var acknowledgementSize: CGSize?
  public var metrics: MessageLayoutMetrics
  public var richMetrics = RichLayoutMetrics()
  /// While a message streams, how many characters of a text body are revealed. The body is
  /// sized by the lines holding them, so the bubble grows a line at a time; nil shows all.
  public var revealedLength: Int?

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
    blocks: [Block] = [],
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
    self.blocks = blocks
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
  /// Bubble bodies may use this fraction of the lane.
  public var maximumBubbleWidthFraction: CGFloat = 0.9
  /// Gap between the lane edge and the bubble body; the tail overhangs into the row inset.
  public var bodyEdgeInset: CGFloat = 2
  public var bubbleInsets = Insets(top: 8, leading: 12, bottom: 8, trailing: 12)
  public var cornerRadius: CGFloat = 18
  /// How far the tail reaches past the bubble body.
  public var tailWidth: CGFloat = 7
  public var nameTopSpacing: CGFloat = 9
  public var nameLeadingInset: CGFloat = 4
  public var nameMinimumHeight: CGFloat = 16
  public var nameBottomSpacing: CGFloat = 0
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
  /// Padding inside the time pill drawn over large emoji.
  public var timeOverlayPadding = CGSize(width: 6, height: 3)
  /// Gap between large emoji and the reactions below them.
  public var emojiReactionsSpacing: CGFloat = 8
  /// Gap between stacked blocks, and between a block and the text.
  public var blockSpacing: CGFloat = 6
  /// Distance of the time pill from the corner of media it overlays.
  public var mediaOverlayInset: CGFloat = 6
  /// Gap between the bubble and blocks under it, and between those blocks.
  public var belowBubbleSpacing: CGFloat = 4

  public init() {}
}

public extension MessageLayoutInput {
  /// The widest content inside a bubble's padding in this row, before blocks narrow it. Hosts
  /// measure blocks against it.
  var maximumContentWidth: CGFloat {
    let m = metrics
    let avatarColumn = isOutgoing || avatar == .none ? 0 : m.avatarSize + m.avatarSpacing
    let lane = max(0, rowWidth - m.rowLeadingInset - m.rowTrailingInset - avatarColumn)
    return max(1, grid.floor(lane * m.maximumBubbleWidthFraction) - m.bubbleInsets.horizontal)
  }
}
