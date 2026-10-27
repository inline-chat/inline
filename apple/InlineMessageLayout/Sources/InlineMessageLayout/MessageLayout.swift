import CoreGraphics

/// Stable identity of a placed element, used to match old and new layouts for animation.
public enum MessageLayoutNode: Hashable, Sendable {
  case avatar
  case name
  case bubble
  case text
  case time
  case acknowledgement
  case reaction(String)
  case block(String)
}

/// Where the time sits relative to the content.
public enum MessageTimePlacement: Hashable, Sendable {
  /// After the last text line, on its baseline.
  case inline
  /// At the trailing end of the last reactions row.
  case reactionsRow
  /// Its own row below the content.
  case below
  /// A pill over the bottom-trailing corner of large emoji, which have no bubble, or of media
  /// with no caption.
  case overlay
}

/// The complete geometry of one message row. Every frame is in row coordinates, y-down,
/// pixel-aligned; nothing is measured again when the view applies it.
public struct MessageLayout: Sendable {
  public struct Bubble: Hashable, Sendable {
    /// Includes the tail.
    public var frame: CGRect
    /// The rounded body without the tail.
    public var body: CGRect
    public var tail: BubbleTailSide
    public var cornerRadius: CGFloat
    /// False for large emoji, which have no bubble.
    public var isVisible: Bool
  }

  public var size: CGSize
  public var bubble: Bubble
  public var frames: [MessageLayoutNode: CGRect]
  /// Nodes laid out but drawn transparent.
  public var hiddenNodes: Set<MessageLayoutNode>
  /// Body text, aligned to its frame's width.
  public var text: TextLayout?
  /// Rich body, in the `.text` frame's coordinates.
  public var rich: RichLayout?
  /// Characters of `text` to draw while a message streams; nil draws all of it.
  public var revealedLength: Int?
  public var name: TextLayout?
  public var time: TextLayout
  public var timePlacement: MessageTimePlacement
  /// Reaction order as laid out, for accessibility and tests.
  public var reactionOrder: [String]
  /// Blocks in reading order.
  public var blockOrder: [String] = []
  /// Blocks drawn to the bubble's edges; the host clips them to the bubble's shape.
  public var edgeToEdgeBlocks: Set<String> = []

  public func frame(_ node: MessageLayoutNode) -> CGRect? {
    frames[node]
  }

  /// Reading order for accessibility.
  public var accessibilityOrder: [MessageLayoutNode] {
    var order: [MessageLayoutNode] = []
    if frames[.name] != nil { order.append(.name) }
    // Blocks above the text read before it, the rest after it.
    let textY = frames[.text]?.minY ?? .greatestFiniteMagnitude
    let blocks = blockOrder.map(MessageLayoutNode.block)
    order += blocks.filter { (frames[$0]?.minY ?? 0) < textY }
    if frames[.text] != nil { order.append(.text) }
    order += blocks.filter { (frames[$0]?.minY ?? 0) >= textY }
    order += reactionOrder.map(MessageLayoutNode.reaction)
    for node in [MessageLayoutNode.acknowledgement, .time] where frames[node] != nil {
      order.append(node)
    }
    return order
  }
}
