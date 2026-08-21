import AppKit

protocol RichBlockTextMenuProviding: AnyObject {
  func richBlockTextMenu(
    nativeMenu: NSMenu,
    event: NSEvent,
    characterIndex: Int,
    attributedText: NSAttributedString
  ) -> NSMenu?
}

final class RichBlockTextSurface: NSView {
  private let label: MessageTextView = {
    let label = MessageTextView(frame: .zero)
    label.isEditable = false
    label.isSelectable = true
    label.usesFontPanel = false
    label.drawsBackground = false
    label.isVerticallyResizable = false
    label.isHorizontallyResizable = false
    label.textContainerInset = .zero
    label.textContainer?.lineFragmentPadding = 0
    label.textContainer?.maximumNumberOfLines = 0
    label.textContainer?.lineBreakMode = .byWordWrapping
    label.textContainer?.widthTracksTextView = true
    label.textContainer?.heightTracksTextView = false
    return label
  }()

  private var text = NSAttributedString()
  private(set) var renderRevision: UInt64 = 0
  private var onEntityClick: ((MessageTextEntityHit, NSAttributedString) -> Bool)?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    label.delegate = self
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var measuredWidth: CGFloat {
    ceil(text.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).width)
  }

  func apply(
    text: NSAttributedString,
    linkColor: NSColor,
    onEntityClick: @escaping (MessageTextEntityHit, NSAttributedString) -> Bool
  ) {
    if !self.text.isEqual(to: text) {
      renderRevision &+= 1
    }
    self.text = text
    self.onEntityClick = onEntityClick
    label.linkTextAttributes = [
      .foregroundColor: linkColor,
      .cursor: NSCursor.pointingHand,
    ]
    label.textStorage?.setAttributedString(text)
    label.onEntityClick = { [weak self, weak label] point, _ in
      guard let self, let label,
            let hit = label.entityHit(at: point, extraTextRanges: [])
      else { return false }
      return self.onEntityClick?(hit, self.text) ?? false
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    label.frame = bounds
    label.textContainer?.size = label.bounds.size
  }

  func hasInteractiveEntity(at point: NSPoint) -> Bool {
    let labelPoint = label.convert(point, from: self)
    return label.bounds.contains(labelPoint)
      && label.entityHit(at: labelPoint, extraTextRanges: []) != nil
  }

  func logicalLineFragments() -> [(number: Int, y: CGFloat, height: CGFloat)] {
    guard let layoutManager = label.layoutManager,
          let textContainer = label.textContainer
    else { return [] }
    label.layoutSubtreeIfNeeded()
    layoutManager.ensureLayout(for: textContainer)

    var logicalLineStarts = [0]
    for (offset, codeUnit) in text.string.utf16.enumerated() where codeUnit == 10 {
      logicalLineStarts.append(offset + 1)
    }
    let glyphRange = layoutManager.glyphRange(for: textContainer)
    var result: [(number: Int, y: CGFloat, height: CGFloat)] = []
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
      let characterRange = layoutManager.characterRange(
        forGlyphRange: fragmentGlyphRange,
        actualGlyphRange: nil
      )
      guard let lineIndex = logicalLineStarts.lastIndex(where: { $0 <= characterRange.location }),
            logicalLineStarts[lineIndex] == characterRange.location
      else { return }
      result.append((lineIndex + 1, usedRect.minY, usedRect.height))
    }
    return result
  }

  func renderedMaskImage() -> CGImage? {
    guard bounds.width >= 1, bounds.height >= 1 else { return nil }
    layoutSubtreeIfNeeded()
    guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    cacheDisplay(in: bounds, to: representation)
    return representation.cgImage
  }
}

extension RichBlockTextSurface: NSTextViewDelegate {
  func textView(
    _: NSTextView,
    menu: NSMenu,
    for event: NSEvent,
    at charIndex: Int
  ) -> NSMenu? {
    var ancestor = superview
    while let view = ancestor {
      if let provider = view as? RichBlockTextMenuProviding {
        return provider.richBlockTextMenu(
          nativeMenu: menu,
          event: event,
          characterIndex: charIndex,
          attributedText: text
        )
      }
      ancestor = view.superview
    }
    return menu
  }
}
