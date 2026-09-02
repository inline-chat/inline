import AppKit
import TextProcessing

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
    let textChanged = !self.text.isEqual(to: text)
    let preservedSelections = textChanged ? preservedSelections(in: text) : []
    if textChanged {
      renderRevision &+= 1
    }
    self.text = text
    label.setAccessibilityValue(RichTextMath.containsRenderedMath(text) ? RichTextMath.sourceText(text) : nil)
    label.linkTextAttributes = [
      .foregroundColor: linkColor,
      .cursor: NSCursor.pointingHand,
    ]
    if textChanged {
      label.textStorage?.setAttributedString(text)
      if !preservedSelections.isEmpty {
        label.selectedRanges = preservedSelections
      }
    }
    updateInteraction(onEntityClick)
    if textChanged {
      needsLayout = true
    }
  }

  func configureTextLongPress(_ handler: ((NSEvent) -> Void)?) {
    guard let handler else {
      label.onTextLongPress = nil
      return
    }
    label.onTextLongPress = { _, event in handler(event) }
  }

  func updateInteraction(
    _ onEntityClick: @escaping (MessageTextEntityHit, NSAttributedString) -> Bool
  ) {
    self.onEntityClick = onEntityClick
    label.onEntityClick = { [weak self, weak label] point, _ in
      guard let self, let label,
            let hit = label.entityHit(at: point, extraTextRanges: [])
      else { return false }
      return self.onEntityClick?(hit, self.text) ?? false
    }
  }

  private func preservedSelections(in nextText: NSAttributedString) -> [NSValue] {
    let textLength = nextText.length
    return label.selectedRanges.compactMap { value -> NSValue? in
      let range = value.rangeValue
      guard range.location != NSNotFound else { return nil }
      if let mapped = RichTextMath.remapSelection(range, from: text, to: nextText) {
        return NSValue(range: mapped)
      }
      let location = min(max(0, range.location), textLength)
      let length = min(max(0, range.length), textLength - location)
      let clamped = NSRange(location: location, length: length)
      guard isUTF16Boundary(clamped.location, in: nextText),
            isUTF16Boundary(NSMaxRange(clamped), in: nextText)
      else { return nil }
      return NSValue(range: clamped)
    }
  }

  private func isUTF16Boundary(_ offset: Int, in text: NSAttributedString) -> Bool {
    guard offset >= 0, offset <= text.length else { return false }
    guard offset > 0, offset < text.length else { return true }
    let source = text.string as NSString
    return !((0xD800 ... 0xDBFF).contains(source.character(at: offset - 1))
      && (0xDC00 ... 0xDFFF).contains(source.character(at: offset)))
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
