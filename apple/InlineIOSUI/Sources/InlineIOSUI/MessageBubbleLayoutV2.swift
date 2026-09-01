import CoreGraphics

public struct MessageLayoutNodeIDV2: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct MessageLayoutInsetsV2: Equatable, Codable, Sendable {
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

  public static let zero = MessageLayoutInsetsV2(top: 0, leading: 0, bottom: 0, trailing: 0)
}

public struct MessageMeasuredNodeV2: Equatable, Codable, Sendable {
  public enum WidthBehavior: String, Codable, Sendable {
    case natural
    case fill
  }

  public enum HorizontalAlignment: String, Codable, Sendable {
    case leading
    case trailing
  }

  public let id: MessageLayoutNodeIDV2
  public let size: CGSize
  public let spacingBefore: CGFloat
  public let widthBehavior: WidthBehavior
  public let forcesMaximumWidth: Bool
  public let horizontalAlignment: HorizontalAlignment
  public let insets: MessageLayoutInsetsV2
  /// Below-bubble accessories may remain legible without widening the body.
  public let minimumWidth: CGFloat?

  public init(
    id: MessageLayoutNodeIDV2,
    size: CGSize,
    spacingBefore: CGFloat = 0,
    widthBehavior: WidthBehavior = .natural,
    forcesMaximumWidth: Bool = false,
    horizontalAlignment: HorizontalAlignment = .leading,
    insets: MessageLayoutInsetsV2 = .zero,
    minimumWidth: CGFloat? = nil
  ) {
    self.id = id
    self.size = size
    self.spacingBefore = spacingBefore
    self.widthBehavior = widthBehavior
    self.forcesMaximumWidth = forcesMaximumWidth
    self.horizontalAlignment = horizontalAlignment
    self.insets = insets
    self.minimumWidth = minimumWidth
  }
}

public struct MessageOverlayNodeV2: Equatable, Codable, Sendable {
  public enum Anchor: String, Codable, Sendable {
    case bottomLeading
    case bottomTrailing
    case center
  }

  public let id: MessageLayoutNodeIDV2
  public let targetID: MessageLayoutNodeIDV2
  public let size: CGSize
  public let anchor: Anchor
  public let insets: MessageLayoutInsetsV2

  public init(
    id: MessageLayoutNodeIDV2,
    targetID: MessageLayoutNodeIDV2,
    size: CGSize,
    anchor: Anchor,
    insets: MessageLayoutInsetsV2 = .zero
  ) {
    self.id = id
    self.targetID = targetID
    self.size = size
    self.anchor = anchor
    self.insets = insets
  }
}

public struct MessageBubbleLayoutInputV2: Equatable, Codable, Sendable {
  public enum Alignment: String, Codable, Sendable {
    case leading
    case trailing
  }

  public enum TailSide: String, Codable, Sendable {
    case none
    case leading
    case trailing
  }

  public struct Footer: Equatable, Codable, Sendable {
    public let textNodeID: MessageLayoutNodeIDV2
    public let metadataNodeID: MessageLayoutNodeIDV2
    public let metadataSize: CGSize
    public let reactionsNodeID: MessageLayoutNodeIDV2?
    public let reactionsSize: CGSize?
    public let isTextSingleLine: Bool
    public let isRTL: Bool
    public let trailingTextLine: MessageFooterLayoutV2.TrailingTextLine?
    public let horizontalSpacing: CGFloat
    public let verticalSpacing: CGFloat

    public init(
      textNodeID: MessageLayoutNodeIDV2,
      metadataNodeID: MessageLayoutNodeIDV2,
      metadataSize: CGSize,
      reactionsNodeID: MessageLayoutNodeIDV2? = nil,
      reactionsSize: CGSize? = nil,
      isTextSingleLine: Bool,
      isRTL: Bool = false,
      trailingTextLine: MessageFooterLayoutV2.TrailingTextLine? = nil,
      horizontalSpacing: CGFloat,
      verticalSpacing: CGFloat
    ) {
      self.textNodeID = textNodeID
      self.metadataNodeID = metadataNodeID
      self.metadataSize = metadataSize
      self.reactionsNodeID = reactionsNodeID
      self.reactionsSize = reactionsSize
      self.isTextSingleLine = isTextSingleLine
      self.isRTL = isRTL
      self.trailingTextLine = trailingTextLine
      self.horizontalSpacing = horizontalSpacing
      self.verticalSpacing = verticalSpacing
    }
  }

  public let containerWidth: CGFloat
  public let maximumBubbleWidth: CGFloat
  public let minimumBubbleWidth: CGFloat
  public let minimumBubbleHeight: CGFloat
  public let alignment: Alignment
  public let tailSide: TailSide
  public let tailWidth: CGFloat
  public let contentInsets: MessageLayoutInsetsV2
  public let flowNodes: [MessageMeasuredNodeV2]
  public let footer: Footer?
  public let overlayNodes: [MessageOverlayNodeV2]
  public let belowBubbleNodes: [MessageMeasuredNodeV2]

  public init(
    containerWidth: CGFloat,
    maximumBubbleWidth: CGFloat,
    minimumBubbleWidth: CGFloat = 0,
    minimumBubbleHeight: CGFloat = 0,
    alignment: Alignment,
    tailSide: TailSide = .none,
    tailWidth: CGFloat = 0,
    contentInsets: MessageLayoutInsetsV2,
    flowNodes: [MessageMeasuredNodeV2],
    footer: Footer? = nil,
    overlayNodes: [MessageOverlayNodeV2] = [],
    belowBubbleNodes: [MessageMeasuredNodeV2] = []
  ) {
    self.containerWidth = containerWidth
    self.maximumBubbleWidth = maximumBubbleWidth
    self.minimumBubbleWidth = minimumBubbleWidth
    self.minimumBubbleHeight = minimumBubbleHeight
    self.alignment = alignment
    self.tailSide = tailSide
    self.tailWidth = tailWidth
    self.contentInsets = contentInsets
    self.flowNodes = flowNodes
    self.footer = footer
    self.overlayNodes = overlayNodes
    self.belowBubbleNodes = belowBubbleNodes
  }
}

public struct MessageBubbleLayoutV2: Equatable, Codable, Sendable {
  public let size: CGSize
  public let bubbleFrame: CGRect
  public let bubbleContentFrame: CGRect
  public let nodeFrames: [MessageLayoutNodeIDV2: CGRect]
  public let footerPlacement: MessageFooterLayoutV2.Placement?

  public init(
    size: CGSize,
    bubbleFrame: CGRect,
    bubbleContentFrame: CGRect,
    nodeFrames: [MessageLayoutNodeIDV2: CGRect],
    footerPlacement: MessageFooterLayoutV2.Placement?
  ) {
    self.size = size
    self.bubbleFrame = bubbleFrame
    self.bubbleContentFrame = bubbleContentFrame
    self.nodeFrames = nodeFrames
    self.footerPlacement = footerPlacement
  }
}

public enum MessageBubbleLayoutPlannerV2 {
  public static func layout(_ input: MessageBubbleLayoutInputV2) -> MessageBubbleLayoutV2? {
    guard isFiniteAndNonnegative(input.containerWidth),
          isFiniteAndNonnegative(input.maximumBubbleWidth),
          isFiniteAndNonnegative(input.minimumBubbleWidth),
          isFiniteAndNonnegative(input.minimumBubbleHeight),
          input.containerWidth > 0,
          input.maximumBubbleWidth > 0,
          input.maximumBubbleWidth <= input.containerWidth,
          input.minimumBubbleWidth <= input.maximumBubbleWidth,
          isFiniteAndNonnegative(input.tailWidth),
          valid(input.contentInsets),
          valid(input.flowNodes),
          valid(input.overlayNodes),
          valid(input.belowBubbleNodes)
    else { return nil }

    let allIDs = input.flowNodes.map(\.id)
      + input.overlayNodes.map(\.id)
      + input.belowBubbleNodes.map(\.id)
    guard Set(allIDs).count == allIDs.count else { return nil }

    let horizontalChrome = input.contentInsets.leading + input.contentInsets.trailing + input.tailWidth
    let maximumContentWidth = input.maximumBubbleWidth - horizontalChrome
    guard maximumContentWidth > 0 else { return nil }

    var resolvedFooter: MessageFooterLayoutV2?
    var contentWidth: CGFloat = 0
    var forcesMaximumWidth = false

    for node in input.flowNodes {
      let outerWidth = node.size.width + node.insets.leading + node.insets.trailing
      contentWidth = max(contentWidth, min(outerWidth, maximumContentWidth))
      if node.forcesMaximumWidth { forcesMaximumWidth = true }
    }

    if let footer = input.footer {
      guard let textNode = input.flowNodes.first(where: { $0.id == footer.textNodeID }),
            !allIDs.contains(footer.metadataNodeID),
            footer.reactionsNodeID.map({ !allIDs.contains($0) }) ?? true,
            (footer.reactionsNodeID == nil) == (footer.reactionsSize == nil)
      else { return nil }

      let maximumFooterWidth = maximumContentWidth
        - textNode.insets.leading
        - textNode.insets.trailing
      guard maximumFooterWidth > 0 else { return nil }

      resolvedFooter = MessageFooterLayoutPlannerV2.layout(
        textSize: CGSize(width: min(textNode.size.width, maximumFooterWidth), height: textNode.size.height),
        metadataSize: footer.metadataSize,
        reactionsSize: footer.reactionsSize,
        isTextSingleLine: footer.isTextSingleLine,
        isRTL: footer.isRTL,
        trailingTextLine: footer.trailingTextLine,
        maximumWidth: maximumFooterWidth,
        horizontalSpacing: footer.horizontalSpacing,
        verticalSpacing: footer.verticalSpacing
      )
      guard let resolvedFooter else { return nil }
      contentWidth = max(
        contentWidth,
        resolvedFooter.size.width + textNode.insets.leading + textNode.insets.trailing
      )
    }

    if forcesMaximumWidth { contentWidth = maximumContentWidth }
    contentWidth = min(maximumContentWidth, max(0, contentWidth))

    let unclampedBubbleWidth = contentWidth + horizontalChrome
    let bubbleWidth = min(
      input.maximumBubbleWidth,
      max(input.minimumBubbleWidth, unclampedBubbleWidth)
    )
    let resolvedContentWidth = max(0, bubbleWidth - horizontalChrome)
    let bubbleX = input.alignment == .leading ? 0 : input.containerWidth - bubbleWidth
    let contentX = bubbleX + input.contentInsets.leading
      + (input.tailSide == .leading ? input.tailWidth : 0)

    var nodeFrames: [MessageLayoutNodeIDV2: CGRect] = [:]
    var y = input.contentInsets.top
    var footerPlacement: MessageFooterLayoutV2.Placement?

    for node in input.flowNodes {
      y += node.spacingBefore + node.insets.top
      if let footer = input.footer,
         node.id == footer.textNodeID,
         let resolvedFooter {
        let footerX = contentX + node.insets.leading
        nodeFrames[node.id] = resolvedFooter.textFrame.offsetBy(dx: footerX, dy: y)
        nodeFrames[footer.metadataNodeID] = resolvedFooter.metadataFrame.offsetBy(dx: footerX, dy: y)
        if let reactionsFrame = resolvedFooter.reactionsFrame,
           let reactionsNodeID = footer.reactionsNodeID {
          nodeFrames[reactionsNodeID] = reactionsFrame.offsetBy(dx: footerX, dy: y)
        }
        y += resolvedFooter.size.height + node.insets.bottom
        footerPlacement = resolvedFooter.placement
      } else {
        let availableNodeWidth = max(
          0,
          resolvedContentWidth - node.insets.leading - node.insets.trailing
        )
        let width = node.widthBehavior == .fill
          ? availableNodeWidth
          : min(node.size.width, availableNodeWidth)
        let x = switch node.horizontalAlignment {
          case .leading:
            contentX + node.insets.leading
          case .trailing:
            contentX + resolvedContentWidth - node.insets.trailing - width
        }
        nodeFrames[node.id] = CGRect(
          x: x,
          y: y,
          width: width,
          height: node.size.height
        )
        y += node.size.height + node.insets.bottom
      }
    }

    let bubbleHeight = max(input.minimumBubbleHeight, y + input.contentInsets.bottom)
    let bubbleFrame = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)
    let bubbleContentFrame = CGRect(
      x: contentX,
      y: input.contentInsets.top,
      width: resolvedContentWidth,
      height: max(0, bubbleHeight - input.contentInsets.top - input.contentInsets.bottom)
    )

    for overlay in input.overlayNodes {
      guard let targetFrame = nodeFrames[overlay.targetID] else { return nil }
      let origin: CGPoint = switch overlay.anchor {
        case .bottomLeading:
          CGPoint(
            x: targetFrame.minX + overlay.insets.leading,
            y: targetFrame.maxY - overlay.insets.bottom - overlay.size.height
          )
        case .bottomTrailing:
          CGPoint(
            x: targetFrame.maxX - overlay.insets.trailing - overlay.size.width,
            y: targetFrame.maxY - overlay.insets.bottom - overlay.size.height
          )
        case .center:
          CGPoint(
            x: targetFrame.midX - overlay.size.width / 2,
            y: targetFrame.midY - overlay.size.height / 2
          )
      }
      nodeFrames[overlay.id] = CGRect(origin: origin, size: overlay.size)
    }

    var rootHeight = bubbleHeight
    for node in input.belowBubbleNodes {
      rootHeight += node.spacingBefore
      let availableNodeWidth = max(
        node.minimumWidth ?? 0,
        resolvedContentWidth - node.insets.leading - node.insets.trailing
      )
      let width = node.widthBehavior == .fill
        ? availableNodeWidth
        : min(node.size.width, availableNodeWidth)
      let x = node.horizontalAlignment == .leading
        ? contentX + node.insets.leading
        : contentX + resolvedContentWidth - node.insets.trailing - width
      let nodeY = rootHeight + node.insets.top
      nodeFrames[node.id] = CGRect(x: x, y: nodeY, width: width, height: node.size.height)
      rootHeight = nodeY + node.size.height + node.insets.bottom
    }

    return MessageBubbleLayoutV2(
      size: CGSize(width: input.containerWidth, height: rootHeight),
      bubbleFrame: bubbleFrame,
      bubbleContentFrame: bubbleContentFrame,
      nodeFrames: nodeFrames,
      footerPlacement: footerPlacement
    )
  }

  private static func valid(_ nodes: [MessageMeasuredNodeV2]) -> Bool {
    nodes.allSatisfy {
      $0.size.width.isFinite && $0.size.height.isFinite
        && $0.size.width >= 0 && $0.size.height >= 0
        && isFiniteAndNonnegative($0.spacingBefore)
        && isFiniteAndNonnegative($0.minimumWidth ?? 0)
        && valid($0.insets)
    }
  }

  private static func valid(_ nodes: [MessageOverlayNodeV2]) -> Bool {
    nodes.allSatisfy {
      $0.size.width.isFinite && $0.size.height.isFinite
        && $0.size.width >= 0 && $0.size.height >= 0
        && valid($0.insets)
    }
  }

  private static func valid(_ insets: MessageLayoutInsetsV2) -> Bool {
    [insets.top, insets.leading, insets.bottom, insets.trailing]
      .allSatisfy(isFiniteAndNonnegative)
  }

  private static func isFiniteAndNonnegative(_ value: CGFloat) -> Bool {
    value.isFinite && value >= 0
  }
}
