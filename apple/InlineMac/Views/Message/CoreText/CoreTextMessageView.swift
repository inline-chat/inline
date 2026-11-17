import AppKit
import CoreText
import InlineKit
import InlineMessageLayout
import TextProcessing

/// Message text drawn by Inline's Core Text renderer instead of `NSTextView`.
///
/// One prepared `TextLayout` answers drawing, hit testing, selection, cursors and
/// accessibility. With TextKit's line boxes (`.fontDefault`) it draws the same pixels as the
/// `MessageTextView` it replaces. Inside the message list the list owns selection, as it does
/// for `MessageTextView`; this view draws the list's range and reports presses.
@MainActor
final class CoreTextMessageView: NSView, MessageTextSurface {
  /// Room around the text for ink that overhangs its line boxes (tall scripts, italics, emoji).
  static let bleed: CGFloat = 6

  private(set) var surfaceText = NSAttributedString()
  private(set) var textLayout: TextLayout = .empty
  private var isRtl = false
  private var layoutWidth: CGFloat = 0
  private var linkColor: NSColor?
  /// Mentions, links, commands, emails and phone numbers, in text order.
  private var entityRanges: [NSRange] = []
  private var inlineCodeRanges: [NSRange] = []
  /// Ranges that show a pointing hand, like NSTextView's `.cursor` attribute.
  private var pointerRanges: [NSRange] = []
  /// Code blocks and the rounded backgrounds drawn behind them.
  private var codeBlocks: [CodeBlockBox] = []

  private let glyphView = CoreTextGlyphView()

  var onEntityClick: ((NSPoint, NSEvent) -> Bool)?
  var onTextLongPress: ((NSPoint, NSEvent) -> Void)?
  var onPlainSingleClick: ((NSPoint, NSEvent) -> Void)?
  /// Builds the text context menu for a right click at a character (nil off the text).
  var onContextMenu: ((Int?, NSEvent) -> NSMenu?)?

  var listSelectionRange: NSRange? {
    didSet {
      guard listSelectionRange != oldValue else { return }
      glyphView.selectionBands = listSelectionRange.map { selectionBands(for: $0) } ?? []
    }
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {}

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    addSubview(glyphView)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { cancelPendingTextHold() }
  }

  // MARK: Content

  /// Same contract as `NSTextView.setMessageAttributedString`: one base direction for the
  /// whole message and a text container of `layoutSize`.
  func setMessageAttributedString(
    _ text: NSAttributedString,
    isRtl: Bool,
    layoutSize: CGSize,
    linkColor: NSColor?
  ) {
    let unchanged = text.isEqual(to: surfaceText) && isRtl == self.isRtl
      && layoutSize.width == layoutWidth && linkColor == self.linkColor
    guard !unchanged else { return }
    surfaceText = text.copy() as! NSAttributedString
    self.isRtl = isRtl
    self.layoutWidth = layoutSize.width
    self.linkColor = linkColor
    indexEntities()
    rebuildLayout()
  }

  /// The text container width changed (the row resized) without new text.
  func setLayoutWidth(_ width: CGFloat) {
    guard width != layoutWidth else { return }
    layoutWidth = width
    rebuildLayout()
  }

  private func rebuildLayout() {
    glyphView.paint = CoreTextMessageText.paint(surfaceText, linkColor: linkColor, appearance: effectiveAppearance)
    textLayout = CoreTextMessageText.layout(surfaceText, isRtl: isRtl, width: layoutWidth)
      .aligned(toWidth: max(1, layoutWidth))
    glyphView.textLayout = textLayout
    codeBlocks = Self.codeBlocks(in: surfaceText, layout: textLayout, width: max(1, layoutWidth))
    glyphView.codeBlocks = codeBlocks
    glyphView.selectionBands = listSelectionRange.map { selectionBands(for: $0) } ?? []
    window?.invalidateCursorRects(for: self)
    NSAccessibility.post(element: self, notification: .valueChanged)
  }

  private func indexEntities() {
    let text = surfaceText
    let fullRange = NSRange(location: 0, length: text.length)
    var entities: [NSRange] = []
    var inlineCode: [NSRange] = []
    var pointer: [NSRange] = []
    let entityKeys: [NSAttributedString.Key] = [
      .mentionUserId, .mentionGroupId, .threadLink, .botCommand, .emailAddress, .phoneNumber, .link,
    ]
    if fullRange.length > 0 {
      for key in entityKeys {
        text.enumerateAttribute(key, in: fullRange) { value, range, _ in
          if value != nil, !entities.contains(range) { entities.append(range) }
        }
      }
      text.enumerateAttribute(.inlineCode, in: fullRange) { value, range, _ in
        if (value as? Bool) == true { inlineCode.append(range) }
      }
      text.enumerateAttribute(.cursor, in: fullRange) { value, range, _ in
        if (value as? NSCursor) == .pointingHand { pointer.append(range) }
      }
    }
    entityRanges = entities.sorted { $0.location < $1.location }
    inlineCodeRanges = inlineCode
    pointerRanges = (pointer + entityRanges).sorted { $0.location < $1.location }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard surfaceText.length > 0 else { return }
    // Colors are painted, so a new appearance doesn't touch the layout.
    glyphView.paint = CoreTextMessageText.paint(surfaceText, linkColor: linkColor, appearance: effectiveAppearance)
  }

  override func layout() {
    super.layout()
    glyphView.frame = bounds.insetBy(dx: -Self.bleed, dy: -Self.bleed)
  }

  // MARK: Geometry

  /// Rects of `range` on its lines, in this view's coordinates.
  func rects(for range: NSRange) -> [CGRect] {
    textLayout.rects(for: clamped(range))
  }

  private func clamped(_ range: NSRange) -> NSRange {
    let length = surfaceText.length
    let location = min(max(0, range.location), length)
    return NSRange(location: location, length: min(range.length, length - location))
  }

  /// One band per selected line that hugs that line's text, the bands meeting with no gaps,
  /// like `MessageTextView.selectionRects(for:)`.
  private func selectionBands(for range: NSRange) -> [CGRect] {
    let range = clamped(range)
    guard range.length > 0 else { return [] }
    let string = surfaceText.string as NSString
    let selectedLines = textLayout.lines.enumerated().filter { NSIntersectionRange($0.element.range, range).length > 0 }
    var bands: [CGRect] = []
    for (position, (index, line)) in selectedLines.enumerated() {
      let piece = NSIntersectionRange(line.range, range)
      let glyphRects = textLayout.rects(for: piece)
      let top = line.frame.minY
      // Reach down to the next selected line so the selection reads as one shape.
      let next = position + 1 < selectedLines.count && selectedLines[position + 1].offset == index + 1
        ? selectedLines[position + 1].element.frame.minY
        : line.frame.maxY
      if let first = glyphRects.first {
        let union = glyphRects.dropFirst().reduce(first) { $0.union($1) }
        bands.append(CGRect(x: union.minX, y: top, width: max(union.width, 4), height: next - top))
      } else if piece.length > 0, Self.isLineBreak(string.character(at: piece.location)) {
        // A selected blank line keeps a sliver so the selection reads as continuous.
        let x = line.direction == .rightToLeft ? line.frame.maxX - 4 : line.frame.minX
        bands.append(CGRect(x: x, y: top, width: 4, height: next - top))
      }
    }
    return bands
  }

  private static func isLineBreak(_ unit: unichar) -> Bool {
    unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
  }

  // MARK: Hit testing (MessageTextSurface)

  func selectionInsertionIndex(at point: NSPoint) -> Int? {
    guard surfaceText.length > 0, textLayout.lineCount > 0 else { return nil }
    return min(max(0, textLayout.closestCaretIndex(to: point)), surfaceText.length)
  }

  func codeBlockRange(at point: NSPoint) -> NSRange? {
    codeBlocks.first { $0.rect.contains(point) }?.range
  }

  /// Where `MessageTextView` puts code block backgrounds: around the code's text, out to the
  /// block's padding (the paragraph indents leave room for it), within the text box's width.
  /// Drawing also clips them to the box's height, as `MessageTextView` clips to its bounds.
  static func codeBlocks(in text: NSAttributedString, layout: TextLayout, width: CGFloat) -> [CodeBlockBox] {
    guard text.length > 0, text.length == layout.length else { return [] }
    let style = CodeBlockStyle.block
    var boxes: [CodeBlockBox] = []
    text.enumerateAttribute(.codeBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
      guard (value as? Bool) == true else { return }
      let lines = layout.lines.filter { NSIntersectionRange($0.range, range).length > 0 }
      guard let first = lines.first, let last = lines.last else { return }
      let glyphs = layout.rects(for: range).reduce(CGRect.null) { $0.union($1) }
      let left = (glyphs.isNull ? first.frame.minX : glyphs.minX) - style.textInsetLeft
      let right = (glyphs.isNull ? first.frame.minX : glyphs.maxX) + style.textInsetRight
      let rect = CGRect(
        x: left,
        y: first.frame.minY - style.verticalPadding,
        width: right - left,
        height: last.frame.maxY - first.frame.minY + style.verticalPadding * 2
      )
      let clipped = rect.intersection(CGRect(
        x: style.blockHorizontalInset,
        y: rect.minY,
        width: width - style.blockHorizontalInset * 2,
        height: rect.height
      ))
      guard !clipped.isNull else { return }
      boxes.append(CodeBlockBox(range: range, rect: clipped, cornerRadius: style.cornerRadius))
    }
    return boxes
  }

  func inlineCodeRange(at point: NSPoint) -> NSRange? {
    inlineCodeRanges.first { range in
      rects(for: range).contains { $0.insetBy(dx: -2, dy: -1).contains(point) }
    }
  }

  func entityHit(at point: NSPoint, extraTextRanges: [NSRange]) -> MessageTextEntityHit? {
    if let range = codeBlockRange(at: point) {
      return .codeBlock(range)
    }
    if let range = inlineCodeRange(at: point) {
      return .inlineCode(range)
    }
    guard surfaceText.length > 0 else { return nil }
    for range in entityRanges + extraTextRanges where range.length > 0 {
      if rects(for: range).contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
        MessageGestureTrace.debug(
          "CoreTextMessageView.entityHit point=\(MessageGestureTrace.point(point)) result=text range=\(MessageGestureTrace.range(range))"
        )
        return .text(range)
      }
    }
    return nil
  }

  func renderedTextContains(_ point: NSPoint) -> Bool {
    guard let line = textLayout.lines.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(CGPoint(x: $0.frame.midX, y: point.y)) })
    else { return false }
    return point.x >= line.frame.minX - 2 && point.x <= line.frame.maxX + 2
  }

  /// The character drawn at `point`, or nil off the glyphs.
  func characterIndex(at point: NSPoint) -> Int? {
    textLayout.characterIndex(at: point)
  }

  func firstLineScreenRect(for range: NSRange) -> NSRect {
    guard let first = rects(for: range).first, let window else { return .zero }
    return window.convertToScreen(convert(first, to: nil))
  }

  // MARK: Events

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let window, window.isKeyWindow else { return nil }
    let hit = super.hitTest(point)
    // The glyph view only draws; presses belong to this view.
    return hit === glyphView ? self : hit
  }

  /// A press that may still end as a plain click on mouse-up.
  private var pendingPlainClick: (windowPoint: NSPoint, location: NSPoint, event: NSEvent)?
  private var textHoldTimer: Timer?
  private var textHoldMonitor: Any?
  private var textHoldStart: NSPoint?
  private var textHoldEvent: NSEvent?
  private var pressLookedUp = false

  private enum TextHold {
    static let duration: TimeInterval = 0.5
    static let movement: CGFloat = 10
  }

  override func mouseDown(with event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    guard let window else { return super.mouseDown(with: event) }
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
      return
    }
    pendingPlainClick = nil
    pressLookedUp = false
    guard event.type == .leftMouseDown, event.clickCount == 1 else { return }
    if onEntityClick?(location, event) ?? false { return }
    if onPlainSingleClick != nil {
      pendingPlainClick = (event.locationInWindow, location, event)
    }
    startTextHold(at: location, event: event)
    // Inside the list, the list tracks this press; there is no native selection to start.
  }

  override func mouseDragged(with _: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    cancelTextHold()
    guard let press = pendingPlainClick else { return }
    pendingPlainClick = nil
    let dx = event.locationInWindow.x - press.windowPoint.x
    let dy = event.locationInWindow.y - press.windowPoint.y
    if dx * dx + dy * dy < 9 {
      onPlainSingleClick?(press.location, press.event)
    }
  }

  func cancelPendingTextHold() {
    cancelTextHold()
    pendingPlainClick = nil
  }

  private func startTextHold(at location: NSPoint, event: NSEvent) {
    guard onTextLongPress != nil else { return }
    cancelTextHold()
    textHoldStart = location
    textHoldEvent = event
    let timer = Timer(timeInterval: TextHold.duration, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let start = self.textHoldStart, let event = self.textHoldEvent else { return }
        let action = self.onTextLongPress
        self.cancelTextHold()
        action?(start, event)
      }
    }
    textHoldTimer = timer
    RunLoop.current.add(timer, forMode: .eventTracking)
    RunLoop.current.add(timer, forMode: .default)
    textHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp,
      .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
    ]) { [weak self] next in
      MainActor.assumeIsolated { self?.updateTextHold(with: next) }
      return next
    }
  }

  private func updateTextHold(with event: NSEvent) {
    guard textHoldTimer != nil, let start = textHoldStart else { return }
    if event.type == .leftMouseDragged {
      let location = convert(event.locationInWindow, from: nil)
      let dx = location.x - start.x
      let dy = location.y - start.y
      if dx * dx + dy * dy > TextHold.movement * TextHold.movement { cancelTextHold() }
    } else {
      cancelTextHold()
    }
  }

  private func cancelTextHold() {
    textHoldTimer?.invalidate()
    textHoldTimer = nil
    textHoldStart = nil
    textHoldEvent = nil
    if let textHoldMonitor {
      NSEvent.removeMonitor(textHoldMonitor)
      self.textHoldMonitor = nil
    }
  }

  // MARK: Look Up

  /// Whether a force click means Look Up (the trackpad default) rather than a three-finger tap.
  private static var forceClickLooksUp: Bool {
    guard UserDefaults.standard.object(forKey: "com.apple.trackpad.forceClick") as? Bool ?? true else { return false }
    let tapGesture = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")?
      .integer(forKey: "TrackpadThreeFingerTapGesture") ?? 0
    return tapGesture != 2
  }

  override func pressureChange(with event: NSEvent) {
    super.pressureChange(with: event)
    guard event.stage >= 2, !pressLookedUp else { return }
    pressLookedUp = true
    takePressForLookUp()
    guard Self.forceClickLooksUp else { return }
    lookUp(at: convert(event.locationInWindow, from: nil))
  }

  override func quickLook(with event: NSEvent) {
    guard !pressLookedUp else { return }
    takePressForLookUp()
    lookUp(at: convert(event.locationInWindow, from: nil))
  }

  private func takePressForLookUp() {
    cancelTextHold()
    pendingPlainClick = nil
    MessageListTextSelection.owner(of: self)?.cancelPendingPress()
  }

  /// The word at `index` worth looking up: one with a letter or a digit.
  private func lookUpWord(at index: Int) -> NSRange? {
    guard surfaceText.length > 0 else { return nil }
    let word = surfaceText.doubleClick(at: min(max(0, index), surfaceText.length - 1))
    guard word.length > 0,
          (surfaceText.string as NSString).substring(with: word).contains(where: { $0.isLetter || $0.isNumber })
    else { return nil }
    return word
  }

  private func lookUp(at point: NSPoint) {
    guard let index = characterIndex(at: point) else { return }
    lookUp(index: index)
  }

  private func lookUp(index: Int) {
    guard let word = lookUpWord(at: index),
          let line = textLayout.lines.first(where: { NSLocationInRange(word.location, $0.range) }),
          let start = rects(for: word).first
    else { return }
    showDefinition(
      for: surfaceText.attributedSubstring(from: word),
      at: NSPoint(x: start.minX, y: line.baseline)
    )
  }

  @objc private func lookUpFromMenu(_ item: NSMenuItem) {
    guard let index = item.representedObject as? Int else { return }
    lookUp(index: index)
  }

  // MARK: Context menu

  override func menu(for event: NSEvent) -> NSMenu? {
    let index = characterIndex(at: convert(event.locationInWindow, from: nil))
    return onContextMenu?(index, event) ?? super.menu(for: event)
  }

  /// The text items NSTextView would offer for a right click at `index`, for the message menu
  /// to pick from: Look Up for the word there.
  func nativeTextMenu(at index: Int?) -> NSMenu {
    let menu = NSMenu()
    if let index, let word = lookUpWord(at: index) {
      let title = (surfaceText.string as NSString).substring(with: word)
      let item = NSMenuItem(title: "Look Up “\(title)”", action: #selector(lookUpFromMenu(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = index
      menu.addItem(item)
    }
    return menu
  }

  // MARK: Cursors

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .iBeam)
    for range in pointerRanges {
      for rect in rects(for: range) {
        addCursorRect(rect, cursor: .pointingHand)
      }
    }
  }

  // MARK: Accessibility

  override func accessibilityValue() -> Any? { surfaceText.string }
  override func accessibilityNumberOfCharacters() -> Int { surfaceText.length }
  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: surfaceText.length)
  }

  override func accessibilitySelectedTextRange() -> NSRange {
    listSelectionRange ?? NSRange(location: 0, length: 0)
  }

  override func accessibilitySelectedText() -> String? {
    guard let range = listSelectionRange, range.length > 0 else { return nil }
    return (surfaceText.string as NSString).substring(with: clamped(range))
  }

  override func accessibilityString(for range: NSRange) -> String? {
    (surfaceText.string as NSString).substring(with: clamped(range))
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    surfaceText.attributedSubstring(from: clamped(range))
  }

  override func accessibilityLine(for index: Int) -> Int {
    textLayout.lines.firstIndex { NSLocationInRange(index, $0.range) } ?? max(0, textLayout.lineCount - 1)
  }

  override func accessibilityRange(forLine line: Int) -> NSRange {
    guard textLayout.lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
    return textLayout.lines[line].range
  }

  override func accessibilityFrame(for range: NSRange) -> NSRect {
    let rects = rects(for: range)
    guard let first = rects.first, let window else { return .zero }
    let union = rects.dropFirst().reduce(first) { $0.union($1) }
    return window.convertToScreen(convert(union, to: nil))
  }

  override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard let window else { return NSRange(location: NSNotFound, length: 0) }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    guard let index = selectionInsertionIndex(at: local), surfaceText.length > 0 else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return (surfaceText.string as NSString).rangeOfComposedCharacterSequence(at: min(index, surfaceText.length - 1))
  }
}

/// Draws a prepared layout. It sits `CoreTextMessageView.bleed` outside its owner on every side
/// so overhanging ink isn't clipped, and never takes events.
@MainActor
final class CoreTextGlyphView: NSView {
  var textLayout: TextLayout = .empty {
    didSet { needsDisplay = true }
  }

  /// Colors and decorations for the layout's text (`CoreTextMessageText.paint`).
  var paint = NSAttributedString() {
    didSet { needsDisplay = true }
  }

  var codeBlocks: [CodeBlockBox] = [] {
    didSet { if codeBlocks != oldValue { needsDisplay = true } }
  }

  /// List selection, in the owner's coordinates.
  var selectionBands: [CGRect] = [] {
    didSet { if selectionBands != oldValue { needsDisplay = true } }
  }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let bleed = CoreTextMessageView.bleed
    context.saveGState()
    context.translateBy(x: bleed, y: bleed)
    let rect = dirtyRect.offsetBy(dx: -bleed, dy: -bleed)

    // Code block backgrounds, then the selection, then text, as MessageTextView draws them.
    let box = bounds.insetBy(dx: bleed, dy: bleed).offsetBy(dx: -bleed, dy: -bleed)
    for block in codeBlocks where block.rect.intersects(rect) {
      let blockRect = block.rect.intersection(box)
      guard !blockRect.isNull else { continue }
      let value = paint.length > block.range.location
        ? paint.attribute(CoreTextMessageText.codeBlockColorKey, at: block.range.location, effectiveRange: nil)
        : nil
      let color: CGColor = value != nil ? (value as! CGColor) : NSColor.labelColor.withAlphaComponent(0.08).cgColor
      context.setFillColor(color)
      context.addPath(CGPath(
        roundedRect: blockRect,
        cornerWidth: block.cornerRadius,
        cornerHeight: block.cornerRadius,
        transform: nil
      ))
      context.fillPath()
    }

    if !selectionBands.isEmpty {
      context.setFillColor(NSColor.selectedTextBackgroundColor.cgColor)
      for band in selectionBands where band.intersects(rect) {
        context.fill(band)
      }
    }

    let text = paint
    let fullRange = NSRange(location: 0, length: text.length == textLayout.length ? text.length : 0)
    if fullRange.length > 0 {
      // Background colors (highlights) fill the font's ascent and descent around the baseline,
      // as TextKit draws them, with the sides floored to pixels.
      let scale = backingScale
      text.enumerateAttribute(CoreTextMessageText.backgroundColorKey, in: fullRange) { value, range, _ in
        guard let value else { return }
        context.setFillColor(value as! CGColor)
        let font = (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 13)
        for line in self.textLayout.lines where NSIntersectionRange(line.range, range).length > 0 {
          for box in self.textLayout.rects(for: NSIntersectionRange(line.range, range)) {
            let top = line.baseline - CTFontGetAscent(font)
            let bottom = line.baseline + CTFontGetDescent(font)
            let minX = (box.minX * scale).rounded(.down) / scale, maxX = (box.maxX * scale).rounded(.down) / scale
            let fill = CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
            if fill.intersects(rect) { context.fill(fill) }
          }
        }
      }
    }

    context.textMatrix = .identity
    let visible = rect.insetBy(dx: 0, dy: -bleed)
    // TextKit draws underlines and strikethroughs beneath the glyphs.
    if fullRange.length > 0 {
      drawDecorations(in: context, text: text, fullRange: fullRange, visible: visible)
    }
    let foregroundKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    let fallback = NSColor.labelColor.cgColor
    func color(at index: Int) -> CGColor {
      guard index >= 0, index < fullRange.length,
            let value = text.attribute(foregroundKey, at: index, effectiveRange: nil)
      else { return fallback }
      return value as! CGColor
    }
    for line in textLayout.lines where line.frame.intersects(visible) {
      context.saveGState()
      context.translateBy(x: line.frame.minX, y: line.baseline)
      context.scaleBy(x: 1, y: -1)
      // The layout draws in the context's fill color; paint each stretch of glyphs in its
      // text's color.
      for run in CTLineGetGlyphRuns(line.ctLine) as? [CTRun] ?? [] {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { continue }
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
        var start = 0
        var current = color(at: indices[0])
        for glyph in 1 ... count {
          let next = glyph < count ? color(at: indices[glyph]) : nil
          guard glyph == count || next != current else { continue }
          context.setFillColor(current)
          context.textPosition = .zero
          CTRunDraw(run, context, CFRange(location: start, length: glyph - start))
          start = glyph
          if let next { current = next }
        }
      }
      context.restoreGState()
    }
    context.restoreGState()
  }

  private var backingScale: CGFloat { max(window?.backingScaleFactor ?? 2, 1) }

  /// Underlines and strikethroughs, placed the way TextKit places them (measured against
  /// TextKit 2 at 12–20 pt, 1x and 2x): the font's thickness rounded up to whole pixels, its top
  /// edge rounded to a pixel, centered `underlinePosition` below the baseline or half the
  /// x-height above it, spanning the glyph advances. Underlines skip glyphs that cross them,
  /// with a point of room on each side.
  private func drawDecorations(in context: CGContext, text: NSAttributedString, fullRange: NSRange, visible: CGRect) {
    let scale = backingScale
    let foregroundKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    func snap(_ x: CGFloat) -> CGFloat { (x * scale).rounded() / scale }
    func draw(
      _ styleKey: NSAttributedString.Key,
      colorKey: NSAttributedString.Key,
      skipsInk: Bool,
      center: (CTFont, CGFloat) -> CGFloat
    ) {
      text.enumerateAttribute(styleKey, in: fullRange) { value, range, _ in
        guard let style = value as? Int, style != 0 else { return }
        let colorValue = text.attribute(colorKey, at: range.location, effectiveRange: nil)
          ?? text.attribute(foregroundKey, at: range.location, effectiveRange: nil)
        let color: CGColor = colorValue != nil ? (colorValue as! CGColor) : NSColor.labelColor.cgColor
        let font = (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 13)
        let thickness = (CTFontGetUnderlineThickness(font) * scale).rounded(.up) / scale
        context.setFillColor(color)
        for line in textLayout.lines where NSIntersectionRange(line.range, range).length > 0 && line.frame.intersects(visible) {
          let boxes = textLayout.rects(for: NSIntersectionRange(line.range, range))
          guard let first = boxes.first else { continue }
          let span = boxes.dropFirst().reduce(first) { $0.union($1) }
          let top = ((center(font, line.baseline) - thickness / 2) * scale).rounded() / scale
          let band = CGRect(x: span.minX, y: top, width: span.width, height: thickness)
          let gaps = skipsInk ? inkGaps(in: band, line: line, range: range) : []
          var x = band.minX
          for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) + [band.maxX ... band.maxX] {
            let left = snap(x), right = snap(min(gap.lowerBound, band.maxX))
            if right > left { context.fill(CGRect(x: left, y: top, width: right - left, height: thickness)) }
            x = max(x, gap.upperBound)
          }
        }
      }
    }
    draw(CoreTextMessageText.underlineStyleKey, colorKey: CoreTextMessageText.underlineColorKey, skipsInk: true) { font, baseline in
      baseline - CTFontGetUnderlinePosition(font)
    }
    draw(CoreTextMessageText.strikethroughStyleKey, colorKey: CoreTextMessageText.strikethroughColorKey, skipsInk: false) { font, baseline in
      baseline - CTFontGetXHeight(font) / 2
    }
  }

  /// Where glyphs of `range` on `line` cross `band`, widened by a point on each side.
  private func inkGaps(in band: CGRect, line: TextLayout.Line, range: NSRange) -> [ClosedRange<CGFloat>] {
    let bandPath = CGPath(rect: band, transform: nil)
    var gaps: [ClosedRange<CGFloat>] = []
    for run in CTLineGetGlyphRuns(line.ctLine) as? [CTRun] ?? [] {
      let attributes = CTRunGetAttributes(run) as NSDictionary
      guard let fontValue = attributes[kCTFontAttributeName] else { continue }
      let font = fontValue as! CTFont
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
      for index in 0 ..< count where NSLocationInRange(indices[index], range) {
        var transform = CGAffineTransform(translationX: line.frame.minX + positions[index].x, y: line.baseline)
          .scaledBy(x: 1, y: -1)
        guard let path = CTFontCreatePathForGlyph(font, glyphs[index], &transform),
              path.boundingBoxOfPath.intersects(band)
        else { continue }
        let crossing = path.intersection(bandPath).boundingBoxOfPath
        guard !crossing.isNull, crossing.width > 0 else { continue }
        gaps.append((crossing.minX - 1) ... (crossing.maxX + 1))
      }
    }
    return gaps
  }
}

struct CodeBlockBox: Equatable {
  let range: NSRange
  let rect: CGRect
  let cornerRadius: CGFloat
}
