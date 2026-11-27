import AppKit
import InlineMacUI
import TextProcessing

protocol RichBlockTextMenuProviding: AnyObject {
  func richBlockMessageMenu() -> NSMenu
  func richBlockTextMenu(
    nativeMenu: NSMenu,
    event: NSEvent,
    characterIndex: Int,
    attributedText: NSAttributedString
  ) -> NSMenu?
}

final class RichBlockTextSurface: NSView {
  /// Text nodes (paragraphs, headings, list items, quotes) draw their text in a layer from a Core Text layout when
  /// `RichBlockLayerText` allows it, measured with the same layout by the planner; other surfaces (titles, chips,
  /// fields, code, single lines) keep TextKit.
  var prefersLayerText = false

  /// TextKit's view, made on first use: a surface drawing in a layer never makes one.
  private var textKitLabel: MessageTextView?
  /// The text and link color TextKit's view shows (it keeps older ones while the layer draws).
  private var textKitText: NSAttributedString?
  private var textKitLinkColor: NSColor?
  /// The Core Text view, made on first use.
  private var layerLabel: CoreTextMessageView?
  private(set) var drawsInLayer = false

  /// streaming: characters of this block's text drawn while its message streams (layer text only; TextKit text
  /// shows whole). Nil draws all of it.
  /// Set when the surface is recycled for another message (`prepareForReuse`); the next text drops the old selection.
  private var showsNewMessage = false

  override func prepareForReuse() {
    super.prepareForReuse()
    setRevealedLength(nil)
    // The list's selection belongs to the message shown; the native one is dropped on the next text.
    textKitLabel?.listSelectionRange = nil
    layerLabel?.listSelectionRange = nil
    showsNewMessage = true
  }

  func setRevealedLength(_ length: Int?) {
    guard let layerLabel else { return }
    layerLabel.revealedLength = drawsInLayer ? length : nil
  }
  /// Text the layer view hasn't laid out yet: a surface gets its text before its frame.
  private var layerTextPending = false

  private var text = NSAttributedString()
  private var linkColor: NSColor?
  private(set) var renderRevision: UInt64 = 0
  private var onEntityClick: ((MessageTextEntityHit, NSAttributedString) -> Bool)?
  private var plainSingleClick: (() -> Void)?
  private var textLongPress: ((NSEvent) -> Void)?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var label: MessageTextView {
    if let textKitLabel { return textKitLabel }
    let label = MessageTextView(frame: bounds)
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
    label.textContainer?.size = bounds.size
    label.delegate = self
    addSubview(label)
    textKitLabel = label
    wireHandlers(label)
    return label
  }

  private var layerView: CoreTextMessageView {
    if let layerLabel { return layerLabel }
    let view = CoreTextMessageView(frame: bounds)
    view.onContextMenu = { [weak self, weak view] index, event in
      guard let self, let view else { return nil }
      return textMenu(nativeMenu: view.nativeTextMenu(at: index, event: event), event: event, characterIndex: index ?? 0)
    }
    addSubview(view)
    layerLabel = view
    wireHandlers(view)
    return view
  }

  var measuredWidth: CGFloat {
    ceil(text.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).width)
  }

  /// The view drawing the text, for the message list's selection across blocks and messages.
  var selectionTextView: any MessageTextSurface { drawsInLayer ? layerView : label }

  func configurePlainSingleClick(_ handler: (() -> Void)?) {
    plainSingleClick = handler
    textKitLabel.map(wireHandlers)
    layerLabel.map(wireHandlers)
  }

  func configureTextLongPress(_ handler: ((NSEvent) -> Void)?) {
    textLongPress = handler
    textKitLabel.map(wireHandlers)
    layerLabel.map(wireHandlers)
  }

  /// Clicks, holds and entity presses, the same on either view.
  private func wireHandlers(_ surface: any MessageTextSurface) {
    surface.onPlainSingleClick = plainSingleClick.map { handler in { _, _ in handler() } }
    surface.onTextLongPress = textLongPress.map { handler in { _, event in handler(event) } }
    surface.onEntityClick = { [weak self, weak surface] point, _ in
      guard let self, let surface, let hit = surface.entityHit(at: point, extraTextRanges: []) else { return false }
      return onEntityClick?(hit, text) ?? false
    }
  }

  func apply(
    text: NSAttributedString,
    linkColor: NSColor,
    singleLine: Bool = false,
    onEntityClick: @escaping (MessageTextEntityHit, NSAttributedString) -> Bool
  ) {
    // The render context hands back the same object for an unchanged node.
    let textChanged = self.text !== text && !self.text.isEqual(to: text)
    if textChanged { renderRevision &+= 1 }
    self.onEntityClick = onEntityClick
    if prefersLayerText, RichBlockLayerText.draws(text, singleLine: singleLine) {
      applyInLayer(text, linkColor: linkColor)
      return
    }
    if drawsInLayer {
      drawsInLayer = false
      layerLabel?.isHidden = true
      label.isHidden = false
      label.frame = bounds
      label.textContainer?.size = bounds.size
    }
    // Container setters invalidate layout even when the value is the same.
    if let container = label.textContainer {
      let maximumLines = singleLine ? 1 : 0
      let lineBreakMode: NSLineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
      if container.maximumNumberOfLines != maximumLines { container.maximumNumberOfLines = maximumLines }
      if container.lineBreakMode != lineBreakMode { container.lineBreakMode = lineBreakMode }
    }
    let shownChanged = textKitText.map { $0 !== text && !$0.isEqual(to: text) } ?? true
    // A recycled surface shows another message: nothing of the old selection carries over.
    let preservedSelections = shownChanged && !showsNewMessage ? preservedSelections(in: text) : []
    if showsNewMessage {
      showsNewMessage = false
      if let textKitLabel, textKitLabel.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
        textKitLabel.setSelectedRange(NSRange(location: 0, length: 0))
      }
    }
    self.text = text
    if shownChanged {
      label.setAccessibilityValue(RichTextMath.containsRenderedMath(text) ? RichTextMath.sourceText(text) : nil)
    }
    self.linkColor = linkColor
    if !(textKitLinkColor?.isEqual(linkColor) ?? false) {
      textKitLinkColor = linkColor
      label.linkTextAttributes = [
        .foregroundColor: linkColor,
        .cursor: NSCursor.pointingHand,
      ]
    }
    if shownChanged {
      textKitText = text
      label.textStorage?.setAttributedString(text)
      if !preservedSelections.isEmpty {
        label.selectedRanges = preservedSelections
      }
      needsLayout = true
    }
  }

  /// The text drawn in a layer from the Core Text layout the planner measured. Laid out now when the surface has its
  /// width, else in the next layout pass.
  private func applyInLayer(_ text: NSAttributedString, linkColor: NSColor) {
    let view = layerView
    if showsNewMessage {
      showsNewMessage = false
      if let textKitLabel, textKitLabel.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
        textKitLabel.setSelectedRange(NSRange(location: 0, length: 0))
      }
    }
    if !drawsInLayer {
      drawsInLayer = true
      textKitLabel?.isHidden = true
      view.isHidden = false
      view.frame = bounds
    }
    self.text = text
    self.linkColor = linkColor
    if bounds.width >= 1 {
      layerTextPending = false
      view.setMessageAttributedString(
        text, isRtl: RichBlockLayerText.isRtl(text), layoutSize: CGSize(width: bounds.width, height: 0),
        linkColor: linkColor
      )
    } else {
      layerTextPending = true
      needsLayout = true
    }
  }

  func updateInteraction(
    _ onEntityClick: @escaping (MessageTextEntityHit, NSAttributedString) -> Bool
  ) {
    self.onEntityClick = onEntityClick
  }

  private func preservedSelections(in nextText: NSAttributedString) -> [NSValue] {
    let textLength = nextText.length
    // Only a real selection is worth carrying: setting an empty one wakes text checking for nothing.
    guard let textKitLabel, let shown = textKitText,
          textKitLabel.selectedRanges.contains(where: { $0.rangeValue.length > 0 })
    else { return [] }
    return textKitLabel.selectedRanges.compactMap { value -> NSValue? in
      let range = value.rangeValue
      guard range.location != NSNotFound else { return nil }
      if let mapped = RichTextMath.remapSelection(range, from: shown, to: nextText) {
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

  private func isUTF16Boundary(_ offset: Int) -> Bool {
    isUTF16Boundary(offset, in: text)
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
    if drawsInLayer, let layerLabel {
      layerLabel.frame = bounds
      if layerTextPending, bounds.width >= 1 {
        layerTextPending = false
        layerLabel.setMessageAttributedString(
          text, isRtl: RichBlockLayerText.isRtl(text), layoutSize: CGSize(width: bounds.width, height: 0),
          linkColor: linkColor
        )
      } else {
        layerLabel.setLayoutWidth(bounds.width)
      }
    } else if let textKitLabel {
      textKitLabel.frame = bounds
      textKitLabel.textContainer?.size = textKitLabel.bounds.size
    }
  }

  func hasInteractiveEntity(at point: NSPoint) -> Bool {
    let surface = selectionTextView
    let local = surface.convert(point, from: self)
    return surface.bounds.contains(local) && surface.entityHit(at: local, extraTextRanges: []) != nil
  }

  func logicalLineFragments() -> [(number: Int, y: CGFloat, height: CGFloat)] {
    var logicalLineStarts = [0]
    for (offset, codeUnit) in text.string.utf16.enumerated() where codeUnit == 10 {
      logicalLineStarts.append(offset + 1)
    }
    if drawsInLayer, let layerLabel {
      var result: [(number: Int, y: CGFloat, height: CGFloat)] = []
      var logicalLineIndex = 0
      for line in layerLabel.textLayout.lines {
        while logicalLineIndex + 1 < logicalLineStarts.count,
              logicalLineStarts[logicalLineIndex + 1] <= line.range.location
        {
          logicalLineIndex += 1
        }
        guard logicalLineStarts[logicalLineIndex] == line.range.location else { continue }
        result.append((logicalLineIndex + 1, line.frame.minY, line.frame.height))
      }
      return result
    }
    guard let layoutManager = label.layoutManager,
          let textContainer = label.textContainer
    else { return [] }
    label.layoutSubtreeIfNeeded()
    layoutManager.ensureLayout(for: textContainer)

    let glyphRange = layoutManager.glyphRange(for: textContainer)
    var result: [(number: Int, y: CGFloat, height: CGFloat)] = []
    var logicalLineIndex = 0
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
      let characterRange = layoutManager.characterRange(
        forGlyphRange: fragmentGlyphRange,
        actualGlyphRange: nil
      )
      while logicalLineIndex + 1 < logicalLineStarts.count,
            logicalLineStarts[logicalLineIndex + 1] <= characterRange.location
      {
        logicalLineIndex += 1
      }
      guard logicalLineStarts[logicalLineIndex] == characterRange.location
      else { return }
      result.append((logicalLineIndex + 1, usedRect.minY, usedRect.height))
    }
    return result
  }

  func renderedMaskImage() -> CGImage? {
    guard bounds.width >= 1, bounds.height >= 1 else { return nil }
    layoutSubtreeIfNeeded()
    // AppKit's caching draws views, not a layer's own drawing: render the layer tree.
    if drawsInLayer, let layer = layerLabel?.layer {
      let scale = max(window?.backingScaleFactor ?? 2, 1)
      let width = Int(ceil(bounds.width * scale))
      let height = Int(ceil(bounds.height * scale))
      guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return nil }
      context.scaleBy(x: scale, y: scale)
      layer.displayIfNeeded()
      layer.sublayers?.forEach { $0.displayIfNeeded() }
      layer.render(in: context)
      return context.makeImage()
    }
    guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    cacheDisplay(in: bounds, to: representation)
    return representation.cgImage
  }
}

extension RichBlockTextSurface: NSTextViewDelegate {
  func textView(
    _ textView: NSTextView,
    menu: NSMenu,
    for event: NSEvent,
    at charIndex: Int
  ) -> NSMenu? {
    ContextMenu.intercept(textMenu(nativeMenu: menu, event: event, characterIndex: charIndex), for: event, in: textView)
  }

  /// The message's text menu, with the text view's own items (Look Up, Translate) for the click.
  fileprivate func textMenu(nativeMenu: NSMenu, event: NSEvent, characterIndex: Int) -> NSMenu? {
    var ancestor = superview
    while let view = ancestor {
      if let provider = view as? RichBlockTextMenuProviding {
        return provider.richBlockTextMenu(
          nativeMenu: nativeMenu,
          event: event,
          characterIndex: characterIndex,
          attributedText: text
        )
      }
      ancestor = view.superview
    }
    return nativeMenu
  }
}
