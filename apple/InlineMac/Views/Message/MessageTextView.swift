import AppKit
import InlineKit
import Logger
import TextProcessing

@MainActor
enum MessageGestureTrace {
  static let prefix = "[MessageGestureTrace]"
  private static let traceDefaultsKey = "messageGestureTraceEnabled"
  private static let log = Log.scoped("MessageGesture", enableTracing: true)
  private(set) static var isEnabled = false
  private static var eventMonitor: Any?

  static func restoreSetting() {
    setEnabled(UserDefaults.standard.bool(forKey: traceDefaultsKey))
  }

  static func setEnabled(_ enabled: Bool) {
    #if DEBUG || DEBUG_BUILD
    UserDefaults.standard.set(enabled, forKey: traceDefaultsKey)
    guard enabled != isEnabled else { return }
    if enabled {
      isEnabled = true
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
      ]) { event in
        trace("dispatch \(eventDescription(event)) firstResponder=\(event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        return event
      }
      trace("enabled")
    } else {
      trace("disabled")
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
      isEnabled = false
    }
    #endif
  }

  nonisolated static func trace(_ message: @autoclosure () -> String) {
    // Some legacy hold helpers are not actor annotated. Never inspect AppKit
    // event state if one of those helpers is torn down off the UI thread.
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated {
      guard isEnabled else { return }
      let event = NSApp.currentEvent
      let line = "\(prefix) event=\(event.map(eventNumber) ?? -1) time=\(event?.timestamp ?? 0) \(message())"
      log.trace(line)
    }
  }

  nonisolated static func debug(_ message: @autoclosure () -> String) {
    trace(message())
  }

  static func eventDescription(_ event: NSEvent) -> String {
    let clicks: Int = switch event.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
      event.clickCount
    default: 0
    }
    return "type=\(event.type.rawValue) number=\(eventNumber(event)) clicks=\(clicks) window=\(event.windowNumber) key=\(event.window?.isKeyWindow == true) point=\(point(event.locationInWindow)) modifiers=\(event.modifierFlags.rawValue)"
  }

  private static func eventNumber(_ event: NSEvent) -> Int {
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
         .rightMouseDown, .rightMouseUp, .rightMouseDragged,
         .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved:
      event.eventNumber
    default: -1
    }
  }

  static func view(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    return "\(type(of: view))@\(ObjectIdentifier(view)) frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds))"
  }

  nonisolated static func point(_ point: NSPoint) -> String {
    "(\(String(format: "%.1f", point.x)),\(String(format: "%.1f", point.y)))"
  }

  nonisolated static func range(_ range: NSRange?) -> String {
    guard let range else { return "nil" }
    return "{loc:\(range.location),len:\(range.length)}"
  }

  nonisolated static func url(_ url: URL?) -> String {
    guard let url else { return "nil" }
    let scheme = url.scheme ?? "nil"
    let host = url.host ?? "nil"
    return "{scheme:\(scheme),host:\(host),pathLen:\(url.path.count),query:\(url.query != nil),fragment:\(url.fragment != nil)}"
  }
}

enum MessageTextEntityHit: CustomStringConvertible {
  case codeBlock(NSRange)
  case inlineCode(NSRange)
  case text(NSRange)

  var description: String {
    switch self {
    case let .codeBlock(range):
      return "codeBlock \(MessageGestureTrace.range(range))"
    case let .inlineCode(range):
      return "inlineCode \(MessageGestureTrace.range(range))"
    case let .text(range):
      return "text \(MessageGestureTrace.range(range))"
    }
  }
}

// Custom NSTextView subclass to handle hit testing
class MessageTextView: NSTextView {
  // Match iOS message rendering: inline code is text-only.
  private static let drawsInlineCodeBackground = false

  var codeBlockStyle = CodeBlockStyle.block
  var inlineCodeStyle = CodeBlockStyle.inline

  // NSTextView can consume click recognizers before their target actions run.
  // The owning message view handles links/entities here and returns true only
  // when the click should not continue into AppKit text selection.
  var onEntityClick: ((NSPoint, NSEvent) -> Bool)?
  var onTextLongPress: ((NSPoint, NSEvent) -> Void)?
  var onPlainSingleClick: ((NSPoint, NSEvent) -> Void)?

  /// The message list's selection in this view. Inside the list, the list owns all text
  /// selection (drags, double and triple clicks, across blocks and messages) and NSTextView's
  /// own tracking never runs; the range is drawn beneath the text whatever the first responder.
  var listSelectionRange: NSRange? {
    didSet {
      guard listSelectionRange != oldValue else { return }
      cachedSelectionRects = nil
      needsDisplay = true
    }
  }

  /// The last computed selection bands, so redraws that don't change the selection, text or
  /// size (other dirty rects, tiles) skip the layout walk. One entry, dropped on any change.
  private var cachedSelectionRects: (range: NSRange, size: NSSize, length: Int, rects: [NSRect])?

  func invalidateListSelectionRects() {
    cachedSelectionRects = nil
  }

  /// A press inside the list that may still end as a plain click on mouse-up.
  private var pendingPlainClick: (windowPoint: NSPoint, location: NSPoint, event: NSEvent)?

  private var textHoldTimer: Timer?
  private var textHoldMonitor: Any?
  private var textHoldStart: NSPoint?

  private enum TextHold {
    static let duration: TimeInterval = 0.5
    static let movement: CGFloat = 10
  }

  deinit {
    cancelTextHold(reason: "deinit")
  }

  override func copy(_ sender: Any?) {
    guard let storage = textStorage else { return }
    let source = NSMutableAttributedString(string: "")
    for value in selectedRanges where value.rangeValue.length > 0 {
      let range = value.rangeValue
      guard range.location >= 0, range.location <= storage.length,
            range.length <= storage.length - range.location else { return }
      if source.length > 0 { source.append(NSAttributedString(string: "\n")) }
      source.append(storage.attributedSubstring(from: range))
    }
    guard source.length > 0 else { return }
    MessageTextPasteboard.copy(source)
  }

  override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard let storage = textStorage,
          selectedRanges.contains(where: { RichTextMath.containsRenderedMath(storage, range: $0.rangeValue) })
    else { return super.writeSelection(to: pasteboard, type: type) }
    let source = NSMutableAttributedString(string: "")
    for value in selectedRanges {
      guard let selection = RichTextMath.sourceAttributedText(storage, range: value.rangeValue) else { return false }
      if source.length > 0 { source.append(NSAttributedString(string: "\n")) }
      source.append(selection)
    }
    if type == .string { return pasteboard.setString(source.string, forType: type) }
    let documentType: NSAttributedString.DocumentType
    switch type {
    case .rtf: documentType = .rtf
    case .rtfd: documentType = .rtfd
    case .html: documentType = .html
    default: return false
    }
    guard let data = try? source.data(from: NSRange(location: 0, length: source.length),
                                      documentAttributes: [.documentType: documentType]) else { return false }
    return pasteboard.setData(data, forType: type)
  }

  override func resignFirstResponder() -> Bool {
    selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
    return super.resignFirstResponder()
  }

  private var listOwnsSelection: Bool {
    MessageListTextSelection.owner(of: self) != nil
  }

  /// Inside the list, only the list moves its rows. Once a text view has fallen back to TextKit 1
  /// (reading `layoutManager` does that), AppKit re-centers its old visible text whenever row
  /// layout resizes it. A row entering from the top then scrolls the whole list up by hundreds of
  /// points while the user scrolls up.
  override func scrollToVisible(_ rect: NSRect) -> Bool {
    if listOwnsSelection { return false }
    return super.scrollToVisible(rect)
  }

  /// The list started a selection drag from this press, so it is no longer a hold.
  func cancelPendingTextHold() {
    cancelTextHold(reason: "listSelection")
    pendingPlainClick = nil
  }

  // MARK: Look Up

  /// This press already looked up a word (force click), so a later Quick Look event skips it.
  private var pressLookedUp = false

  /// NSTextView's force-press recognizer expects its own mouse tracking, which never runs inside
  /// the list. Turn it off there; force click and Quick Look are handled below instead.
  private func syncNativeForcePress() {
    let native = !listOwnsSelection
    // AppKit's force press recognizer has no public type.
    for recognizer in gestureRecognizers
      where NSStringFromClass(type(of: recognizer)) == "NSImmediateActionGestureRecognizer"
    {
      if recognizer.isEnabled != native { recognizer.isEnabled = native }
    }
  }

  /// Whether a force click means Look Up (the trackpad default) rather than a three-finger tap.
  private static var forceClickLooksUp: Bool {
    guard UserDefaults.standard.object(forKey: "com.apple.trackpad.forceClick") as? Bool ?? true else { return false }
    let tapGesture = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")?
      .integer(forKey: "TrackpadThreeFingerTapGesture") ?? 0
    return tapGesture != 2
  }

  override func pressureChange(with event: NSEvent) {
    super.pressureChange(with: event)
    guard listOwnsSelection, event.stage >= 2, !pressLookedUp else { return }
    pressLookedUp = true
    MessageGestureTrace.debug("MessageTextView.forceClick point=\(MessageGestureTrace.point(convert(event.locationInWindow, from: nil)))")
    takePressForLookUp()
    guard Self.forceClickLooksUp else { return }
    lookUp(at: convert(event.locationInWindow, from: nil))
  }

  override func quickLook(with event: NSEvent) {
    guard listOwnsSelection else { return super.quickLook(with: event) }
    guard !pressLookedUp else { return }
    takePressForLookUp()
    lookUp(at: convert(event.locationInWindow, from: nil))
  }

  /// Look Up owns the press: no hold action, plain click or selection drag follows it.
  private func takePressForLookUp() {
    cancelTextHold(reason: "lookUp")
    pendingPlainClick = nil
    MessageListTextSelection.owner(of: self)?.cancelPendingPress()
  }

  /// Shows the system definition popover for the word under the point.
  private func lookUp(at point: NSPoint) {
    guard let textStorage, let index = characterIndex(at: point) else { return }
    let word = textStorage.doubleClick(at: index)
    guard word.length > 0,
          (textStorage.string as NSString).substring(with: word).contains(where: { $0.isLetter || $0.isNumber })
    else { return }
    showDefinition(for: nil, range: word)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Prevent hit testing when window is inactive
    guard let window, window.isKeyWindow else {
      MessageGestureTrace.trace("MessageTextView.hitTest blocked inactiveWindow point=\(MessageGestureTrace.point(point))")
      return nil
    }
    let hit = super.hitTest(point)
    MessageGestureTrace.trace(
      "MessageTextView.hitTest point=\(MessageGestureTrace.point(point)) hit=\(String(describing: hit.map { type(of: $0) }))"
    )
    return hit
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    disableSystemTextChecking()
    syncNativeForcePress()
  }

  override func mouseDown(with event: NSEvent) {
    defer { MessageGestureTrace.trace("MessageTextView.mouseDown ended selectionLength=\(selectedRange().length) plainClick=\(onPlainSingleClick != nil)") }
    disableSystemTextChecking()
    let location = convert(event.locationInWindow, from: nil)
    MessageGestureTrace.debug(
      "MessageTextView.mouseDown clickCount=\(event.clickCount) point=\(MessageGestureTrace.point(location)) type=\(event.type.rawValue)"
    )

    // Ensure window is key before handling mouse events
    guard let window else {
      MessageGestureTrace.debug("MessageTextView.mouseDown noWindow forwardingToSuper")
      super.mouseDown(with: event)
      return
    }

    if !window.isKeyWindow {
      MessageGestureTrace.debug("MessageTextView.mouseDown inactiveWindow makeKeyAndReturn")
      window.makeKeyAndOrderFront(nil)
      // Optionally, you can choose to not forward the event
      return
    }

    pendingPlainClick = nil
    pressLookedUp = false
    let ownsSelection = listOwnsSelection
    syncNativeForcePress()
    var plainClickOrigin: NSPoint?
    if event.type == .leftMouseDown, event.clickCount == 1 {
      let handled = onEntityClick?(location, event) ?? false
      MessageGestureTrace.debug(
        "MessageTextView.mouseDown entityClickAttempt point=\(MessageGestureTrace.point(location)) handled=\(handled)"
      )
      if handled { return }
      if onPlainSingleClick != nil {
        plainClickOrigin = event.locationInWindow
      }
      startTextHold(at: location, event: event)
    }

    if ownsSelection {
      // The message list tracks this press; the mouse-up arrives in mouseUp(with:).
      if let plainClickOrigin {
        pendingPlainClick = (plainClickOrigin, location, event)
      }
      MessageGestureTrace.trace("MessageTextView.mouseDown listOwnsSelection")
      return
    }

    MessageGestureTrace.trace("MessageTextView.mouseDown forwardingToSuper")
    super.mouseDown(with: event)
    cancelTextHold(reason: "mouseDownReturn")
    // NSTextView tracks through mouse-up inside mouseDown. Use that event's
    // location: the global cursor may already have moved, or differ entirely
    // from the location of an accessibility-generated click.
    let trackingEvent = NSApp.currentEvent
    let mouseUp = trackingEvent.flatMap { candidate -> NSEvent? in
      guard candidate.type == .leftMouseUp,
            candidate.windowNumber == event.windowNumber,
            candidate.timestamp >= event.timestamp else { return nil }
      return candidate
    }
    let finalWindowPoint = mouseUp?.locationInWindow ?? event.locationInWindow
    if let plainClickOrigin,
       mouseUp != nil,
       !selectedRanges.contains(where: { $0.rangeValue.length > 0 })
    {
      let dx = finalWindowPoint.x - plainClickOrigin.x
      let dy = finalWindowPoint.y - plainClickOrigin.y
      MessageGestureTrace.debug("MessageTextView.plainClick movementSquared=\(dx * dx + dy * dy)")
      if dx * dx + dy * dy < 9 {
        onPlainSingleClick?(location, event)
      }
    }
    if mouseUp != nil, !event.modifierFlags.contains(.control) {
      MessageSelectionMenu.selectionTrackingEnded(in: self, at: finalWindowPoint)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTextView.mouseDragged \(MessageGestureTrace.eventDescription(event))")
    // Inside the list, NSTextView never began tracking; the list owns the drag.
    guard !listOwnsSelection else { return }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MessageTextView.mouseUp \(MessageGestureTrace.eventDescription(event))")
    guard listOwnsSelection else {
      super.mouseUp(with: event)
      return
    }
    cancelTextHold(reason: "mouseUp")
    guard let press = pendingPlainClick else { return }
    pendingPlainClick = nil
    let dx = event.locationInWindow.x - press.windowPoint.x
    let dy = event.locationInWindow.y - press.windowPoint.y
    if dx * dx + dy * dy < 9 {
      onPlainSingleClick?(press.location, press.event)
    }
  }

  private func startTextHold(at location: NSPoint, event: NSEvent) {
    guard onTextLongPress != nil else { return }

    cancelTextHold(reason: "restart")
    textHoldStart = location
    MessageGestureTrace.debug(
      "MessageTextView.textHold start point=\(MessageGestureTrace.point(location)) eventNumber=\(event.eventNumber)"
    )

    let timer = Timer(timeInterval: TextHold.duration, repeats: false) { [weak self, event] _ in
      guard let self, let start = self.textHoldStart else { return }
      guard !self.cancelTextHoldIfSelectionStarted(source: "fire") else { return }
      let action = self.onTextLongPress
      self.cancelTextHold(reason: "fire")
      MessageGestureTrace.debug(
        "MessageTextView.textHold action=fire point=\(MessageGestureTrace.point(start)) eventNumber=\(event.eventNumber)"
      )
      action?(start, event)
    }
    textHoldTimer = timer
    RunLoop.current.add(timer, forMode: .eventTracking)
    RunLoop.current.add(timer, forMode: .default)

    textHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDragged,
      .rightMouseDragged,
      .otherMouseDragged,
      .leftMouseUp,
      .rightMouseDown,
      .rightMouseUp,
      .otherMouseDown,
      .otherMouseUp,
      .scrollWheel,
    ]) { [weak self] next in
      self?.updateTextHold(with: next)
      return next
    }
  }

  private func updateTextHold(with event: NSEvent) {
    guard textHoldTimer != nil, let start = textHoldStart else { return }

    switch event.type {
    case .leftMouseDragged:
      if cancelTextHoldIfSelectionStarted(source: "drag") { return }

      let location = convert(event.locationInWindow, from: nil)
      let dx = location.x - start.x
      let dy = location.y - start.y
      let distanceSquared = (dx * dx) + (dy * dy)
      if distanceSquared > TextHold.movement * TextHold.movement {
        MessageGestureTrace.debug(
          "MessageTextView.textHold action=cancel reason=drag point=\(MessageGestureTrace.point(location))"
        )
        cancelTextHold(reason: "drag")
      }

      DispatchQueue.main.async { [weak self] in
        _ = self?.cancelTextHoldIfSelectionStarted(source: "dragDeferred")
      }
    case .leftMouseUp:
      MessageGestureTrace.debug("MessageTextView.textHold action=cancel reason=mouseUp")
      cancelTextHold(reason: "mouseUp")
    case .rightMouseDown, .rightMouseUp:
      MessageGestureTrace.debug("MessageTextView.textHold action=cancel reason=rightMouse")
      cancelTextHold(reason: "rightMouse")
    case .otherMouseDown, .otherMouseUp:
      MessageGestureTrace.debug("MessageTextView.textHold action=cancel reason=otherMouse")
      cancelTextHold(reason: "otherMouse")
    case .rightMouseDragged, .otherMouseDragged:
      MessageGestureTrace.debug("MessageTextView.textHold action=cancel reason=otherDrag")
      cancelTextHold(reason: "otherDrag")
    case .scrollWheel:
      MessageGestureTrace.debug("MessageTextView.textHold action=cancel reason=scroll")
      cancelTextHold(reason: "scroll")
    default:
      break
    }
  }

  private func cancelTextHoldIfSelectionStarted(source: String) -> Bool {
    guard textHoldTimer != nil else { return false }
    guard selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return false }
    MessageGestureTrace.debug("MessageTextView.textHold action=cancel reason=selection source=\(source)")
    cancelTextHold(reason: "selection")
    return true
  }

  private func cancelTextHold(reason: String) {
    if textHoldTimer != nil {
      MessageGestureTrace.trace("MessageTextView.textHold cancel reason=\(reason)")
    }
    textHoldTimer?.invalidate()
    textHoldTimer = nil
    textHoldStart = nil

    if let textHoldMonitor {
      NSEvent.removeMonitor(textHoldMonitor)
      self.textHoldMonitor = nil
    }
  }

  private func disableSystemTextChecking() {
    // Message text is rendered read-only content. AppKit can still run text checking,
    // inline prediction, or Writing Tools while tracking selection, which has shown
    // up in hangs inside NSTextCheckingController. Inline handles links/entities itself.
    isContinuousSpellCheckingEnabled = false
    isGrammarCheckingEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    isAutomaticTextCompletionEnabled = false
    smartInsertDeleteEnabled = false
    enabledTextCheckingTypes = 0

    if #available(macOS 14.0, *) {
      inlinePredictionType = .no
    }

    if #available(macOS 15.0, *) {
      writingToolsBehavior = .none
      mathExpressionCompletionType = .no
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    drawCodeBlocks(in: dirtyRect)
    drawInlineCode(in: dirtyRect)
    drawListSelection(in: dirtyRect)
    super.draw(dirtyRect)
  }

  private func drawListSelection(in dirtyRect: NSRect) {
    guard let selection = listSelectionRange, selection.length > 0,
          let textStorage, selection.location >= 0,
          selection.location < textStorage.length
    else { return }
    let range = NSRange(
      location: selection.location,
      length: min(selection.length, textStorage.length - selection.location)
    )
    let rects: [NSRect]
    if let cached = cachedSelectionRects, cached.range == range, cached.size == bounds.size,
       cached.length == textStorage.length
    {
      rects = cached.rects
    } else {
      rects = selectionRects(for: range)
      cachedSelectionRects = (range, bounds.size, textStorage.length, rects)
    }
    NSColor.selectedTextBackgroundColor.setFill()
    for rect in rects where rect.intersects(dirtyRect) {
      rect.fill()
    }
  }

  /// Line-by-line selection rectangles in view coordinates, one band per line that hugs that
  /// line's text, like Telegram. The native highlight runs a selected line break out to the
  /// container edge (and merges full middle lines into one segment), which reads as one block.
  func selectionRects(for range: NSRange) -> [NSRect] {
    // Selection segments give the vertical extent (full line height, contiguous); the text's own
    // segments, measured between line breaks, give each line's horizontal extent.
    var segments: [NSRect] = []
    var text: [NSRect] = []
    let pieces = textStorage.map { Self.lineBreakPieces(in: range, of: $0.string as NSString) }
      ?? (runs: [], emptyLines: [])
    if let textLayoutManager, let textContentManager = textLayoutManager.textContentManager {
      // Resolve locations by walking forward from the previous piece, not from the document
      // start each time, so long selections stay linear.
      guard let rangeStart = textContentManager.location(
        textContentManager.documentRange.location,
        offsetBy: range.location
      ),
        let rangeEnd = textContentManager.location(rangeStart, offsetBy: range.length),
        let textRange = NSTextRange(location: rangeStart, end: rangeEnd)
      else { return [] }
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .selection,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        segments.append(segmentRect)
        return true
      }
      var cursor = (offset: range.location, location: rangeStart)
      func standardRects(_ range: NSRange) -> [NSRect] {
        guard let start = textContentManager.location(cursor.location, offsetBy: range.location - cursor.offset),
              let end = textContentManager.location(start, offsetBy: range.length),
              let pieceRange = NSTextRange(location: start, end: end)
        else { return [] }
        cursor = (range.location, start)
        var rects: [NSRect] = []
        textLayoutManager.enumerateTextSegments(
          in: pieceRange,
          type: .standard,
          options: [.rangeNotRequired]
        ) { _, segmentRect, _, _ in
          rects.append(segmentRect)
          return true
        }
        return rects
      }
      // Pieces in document order so the cursor only moves forward.
      let ordered = (pieces.runs.map { ($0, false) } + pieces.emptyLines.map { ($0, true) })
        .sorted { $0.0.location < $1.0.location }
      for (piece, isBlankLine) in ordered {
        let rects = standardRects(piece)
        text += isBlankLine ? rects.prefix(1).map { Self.sliver(at: $0) } : rects
      }
    } else if let layoutManager, let textContainer {
      let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      guard glyphRange.length > 0 else { return [] }
      layoutManager.enumerateEnclosingRects(
        forGlyphRange: glyphRange,
        withinSelectedGlyphRange: glyphRange,
        in: textContainer
      ) { rect, _ in
        segments.append(rect)
      }
      for run in pieces.runs {
        let runGlyphs = layoutManager.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
        layoutManager.enumerateLineFragments(forGlyphRange: runGlyphs) { _, _, container, lineRange, _ in
          let selected = NSIntersectionRange(lineRange, runGlyphs)
          guard selected.length > 0 else { return }
          text.append(layoutManager.boundingRect(forGlyphRange: selected, in: container))
        }
      }
      for lineBreak in pieces.emptyLines {
        let glyphs = layoutManager.glyphRange(forCharacterRange: lineBreak, actualCharacterRange: nil)
        guard glyphs.length > 0 else { continue }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphs.location)
        text.append(Self.sliver(at: NSRect(x: fragment.minX + location.x, y: fragment.minY, width: 0, height: fragment.height)))
      }
    }
    let inset = textContainerInset
    return Self.lineBands(segments: segments, text: text)
      .map { $0.offsetBy(dx: inset.width, dy: inset.height) }
  }

  /// Width a selected blank line keeps, so a selection through it reads as continuous.
  private static let blankLineWidth: CGFloat = 4

  private static func sliver(at rect: NSRect) -> NSRect {
    NSRect(x: rect.minX, y: rect.minY, width: blankLineWidth, height: rect.height)
  }

  /// The parts of `range` between line breaks, and the line breaks that make up a blank line
  /// (a break right after another break or at the start of the range).
  static func lineBreakPieces(in range: NSRange, of string: NSString) -> (runs: [NSRange], emptyLines: [NSRange]) {
    let upper = min(NSMaxRange(range), string.length)
    var runs: [NSRange] = []
    var emptyLines: [NSRange] = []
    var start = range.location
    var index = range.location
    while index < upper {
      let unit = string.character(at: index)
      if unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85 {
        if index > start {
          runs.append(NSRange(location: start, length: index - start))
        } else if unit != 0x0A || index == 0 || string.character(at: index - 1) != 0x0D {
          emptyLines.append(NSRange(location: index, length: 1))
        }
        start = index + 1
      }
      index += 1
    }
    if upper > start { runs.append(NSRange(location: start, length: upper - start)) }
    return (runs, emptyLines)
  }

  /// Splits selection segments into one band per line of text. Bands span the segment's height
  /// without gaps (neighbors meet halfway) and hug their line's text horizontally.
  static func lineBands(segments: [NSRect], text: [NSRect]) -> [NSRect] {
    var bands: [NSRect] = []
    let text = text.sorted { $0.minY < $1.minY }
    for segment in segments {
      // The text in this segment, grouped into lines by vertical overlap.
      var lines: [NSRect] = []
      for rect in text
        where rect.midY > segment.minY && rect.midY < segment.maxY
          && rect.maxX > segment.minX && rect.minX < segment.maxX
      {
        if let last = lines.last, rect.minY < last.maxY - 0.5 {
          lines[lines.count - 1] = last.union(rect)
        } else {
          lines.append(rect)
        }
      }
      guard !lines.isEmpty else {
        // A selected line break on a line with text elsewhere (RTL puts it at the far edge).
        if text.contains(where: { $0.midY > segment.minY && $0.midY < segment.maxY }) { continue }
        bands.append(NSRect(x: segment.minX, y: segment.minY, width: min(blankLineWidth, segment.width), height: segment.height))
        continue
      }
      for (index, line) in lines.enumerated() {
        let top = index == 0 ? segment.minY : (lines[index - 1].maxY + line.minY) / 2
        let bottom = index == lines.count - 1 ? segment.maxY : (line.maxY + lines[index + 1].minY) / 2
        let left = max(segment.minX, line.minX)
        let right = min(segment.maxX, line.maxX)
        bands.append(NSRect(x: left, y: top, width: max(right - left, blankLineWidth), height: bottom - top))
      }
    }
    return bands
  }

  func codeBlockRange(at point: NSPoint) -> NSRange? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    var match: NSRange?
    textStorage.enumerateAttribute(.codeBlock, in: fullRange, options: []) { value, range, stop in
      guard (value as? Bool) == true else { return }
      guard let blockRect = codeBlockRect(for: range, style: codeBlockStyle),
            blockRect.contains(point)
      else { return }
      match = range
      stop.pointee = true
    }
    return match
  }

  func inlineCodeRange(at point: NSPoint) -> NSRange? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    var match: NSRange?
    textStorage.enumerateAttribute(.inlineCode, in: fullRange, options: []) { value, range, stop in
      guard (value as? Bool) == true else { return }
      guard inlineCodeRects(for: range, style: inlineCodeStyle).contains(where: { $0.contains(point) }) else {
        return
      }
      match = range
      stop.pointee = true
    }
    return match
  }

  func entityHit(at point: NSPoint, extraTextRanges: [NSRange]) -> MessageTextEntityHit? {
    if let codeRange = codeBlockRange(at: point) {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=codeBlock range=\(MessageGestureTrace.range(codeRange))"
      )
      return .codeBlock(codeRange)
    }

    if let inlineCodeRange = inlineCodeRange(at: point) {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=inlineCode range=\(MessageGestureTrace.range(inlineCodeRange))"
      )
      return .inlineCode(inlineCodeRange)
    }

    guard let textStorage, textStorage.length > 0 else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=nil reason=noTextStorage"
      )
      return nil
    }

    guard let characterIndex = characterIndex(at: point), characterIndex < textStorage.length else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) result=nil reason=noCharacterIndex"
      )
      return nil
    }

    let ranges = entityRanges(in: textStorage, extraRanges: extraTextRanges)
    guard let range = ranges.first(where: { NSLocationInRange(characterIndex, $0) }) else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) char=\(characterIndex) result=nil reason=noEntity"
      )
      return nil
    }

    guard renderedRange(range, contains: point) else {
      MessageGestureTrace.debug(
        "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) char=\(characterIndex) result=nil reason=outsideRenderedEntity range=\(MessageGestureTrace.range(range))"
      )
      return nil
    }

    MessageGestureTrace.debug(
      "MessageTextView.entityHit point=\(MessageGestureTrace.point(point)) char=\(characterIndex) result=text range=\(MessageGestureTrace.range(range))"
    )
    return .text(range)
  }

  func renderedTextContains(_ point: NSPoint) -> Bool {
    let range = renderedCharacterRange(at: point)
    let contains = range != nil
    MessageGestureTrace.trace(
      "MessageTextView.renderedTextContains point=\(MessageGestureTrace.point(point)) contains=\(contains) range=\(MessageGestureTrace.range(range))"
    )
    return contains
  }

  private func entityRanges(in textStorage: NSTextStorage, extraRanges: [NSRange]) -> [NSRange] {
    let fullRange = NSRange(location: 0, length: textStorage.length)
    let keys: [NSAttributedString.Key] = [
      .mentionUserId,
      .mentionGroupId,
      .threadLink,
      .botCommand,
      .emailAddress,
      .phoneNumber,
      .link,
    ]

    var ranges = extraRanges
    for key in keys {
      textStorage.enumerateAttribute(key, in: fullRange, options: []) { value, range, _ in
        guard value != nil else { return }
        ranges.append(range)
      }
    }

    return normalizedRanges(ranges, maxLength: textStorage.length)
  }

  private func characterIndex(at point: NSPoint) -> Int? {
    guard let textStorage, textStorage.length > 0 else { return nil }

    if let layoutManager, let textContainer {
      let containerPoint = NSPoint(
        x: point.x - textContainerInset.width,
        y: point.y - textContainerInset.height
      )
      let characterIndex = layoutManager.characterIndex(
        for: containerPoint,
        in: textContainer,
        fractionOfDistanceBetweenInsertionPoints: nil
      )
      guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
      return characterIndex
    }

    let characterIndex = characterIndexForInsertion(at: point)
    guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
    return characterIndex
  }

  /// Native insertion offset used by the message-local rich selection owner.
  /// Unlike entity hit testing, the trailing text boundary is a valid endpoint.
  func selectionInsertionIndex(at point: NSPoint) -> Int? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    let index = characterIndexForInsertion(at: point)
    guard index != NSNotFound, (0 ... textStorage.length).contains(index) else { return nil }
    return index
  }

  private func renderedCharacterRange(at point: NSPoint) -> NSRange? {
    guard let textStorage, textStorage.length > 0 else { return nil }

    if let layoutManager, let textContainer {
      let containerPoint = NSPoint(
        x: point.x - textContainerInset.width,
        y: point.y - textContainerInset.height
      )
      var fraction: CGFloat = 0
      let glyphIndex = layoutManager.glyphIndex(
        for: containerPoint,
        in: textContainer,
        fractionOfDistanceThroughGlyph: &fraction
      )
      guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

      var glyphRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyphIndex, length: 1),
        in: textContainer
      )
      glyphRect.origin.x += textContainerInset.width
      glyphRect.origin.y += textContainerInset.height
      guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }

      let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
      guard characterIndex != NSNotFound, characterIndex < textStorage.length else { return nil }
      return NSRange(location: characterIndex, length: 1)
    }

    guard let characterIndex = characterIndex(at: point) else { return nil }
    let characterRange = NSRange(location: characterIndex, length: 1)
    return renderedStandardRange(characterRange, contains: point) ? characterRange : nil
  }

  private func renderedRange(_ range: NSRange, contains point: NSPoint) -> Bool {
    if let textLayoutManager, let textContentManager = textLayoutManager.textContentManager {
      guard let textRange = textRange(for: range, in: textContentManager) else { return false }
      var contains = false
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .selection,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += self.textContainerInset.width
        adjusted.origin.y += self.textContainerInset.height
        if adjusted.insetBy(dx: -1, dy: -1).contains(point) {
          contains = true
          return false
        }
        return true
      }
      return contains
    }

    guard let layoutManager, let textContainer else { return false }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return false }

    var contains = false
    layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphRange,
      withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: textContainer
    ) { rect, stop in
      var adjusted = rect
      adjusted.origin.x += self.textContainerInset.width
      adjusted.origin.y += self.textContainerInset.height
      if adjusted.insetBy(dx: -1, dy: -1).contains(point) {
        contains = true
        stop.pointee = true
      }
    }
    return contains
  }

  private func renderedStandardRange(_ range: NSRange, contains point: NSPoint) -> Bool {
    if let textLayoutManager, let textContentManager = textLayoutManager.textContentManager {
      guard let textRange = textRange(for: range, in: textContentManager) else { return false }
      var contains = false
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .standard,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += self.textContainerInset.width
        adjusted.origin.y += self.textContainerInset.height
        if adjusted.insetBy(dx: -2, dy: -2).contains(point) {
          contains = true
          return false
        }
        return true
      }
      return contains
    }

    return renderedRange(range, contains: point)
  }

  private func textRange(for range: NSRange, in textContentManager: NSTextContentManager) -> NSTextRange? {
    let documentRange = textContentManager.documentRange
    guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
          let endLocation = textContentManager.location(startLocation, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: startLocation, end: endLocation)
  }

  private func normalizedRanges(_ ranges: [NSRange], maxLength: Int) -> [NSRange] {
    var result: [NSRange] = []

    for range in ranges {
      guard range.location != NSNotFound,
            range.location < maxLength,
            range.length > 0
      else { continue }

      let end = min(maxLength, range.location + range.length)
      guard end > range.location else { continue }

      let safeRange = NSRange(location: range.location, length: end - range.location)
      guard !result.contains(where: { NSEqualRanges($0, safeRange) }) else { continue }
      result.append(safeRange)
    }

    return result
  }

  private func drawCodeBlocks(in rect: NSRect) {
    guard let textStorage, textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.codeBlock, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      guard let blockRect = codeBlockRect(for: range, style: codeBlockStyle),
            blockRect.intersects(rect)
      else { return }
      let backgroundColor = (textStorage.attribute(.codeBlockBackground, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor.withAlphaComponent(0.08)
      let path = NSBezierPath(roundedRect: blockRect, xRadius: codeBlockStyle.cornerRadius, yRadius: codeBlockStyle.cornerRadius)
      backgroundColor.setFill()
      path.fill()
    }
  }

  private func drawInlineCode(in rect: NSRect) {
    guard Self.drawsInlineCodeBackground else { return }

    guard let textStorage, textStorage.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.inlineCode, in: fullRange, options: []) { value, range, _ in
      guard (value as? Bool) == true else { return }
      let backgroundColor = (textStorage.attribute(.inlineCodeBackground, at: range.location, effectiveRange: nil)
        as? NSColor) ?? NSColor.labelColor.withAlphaComponent(0.12)
      for inlineRect in inlineCodeRects(for: range, style: inlineCodeStyle) where inlineRect.intersects(rect) {
        let path = NSBezierPath(
          roundedRect: inlineRect,
          xRadius: inlineCodeStyle.cornerRadius,
          yRadius: inlineCodeStyle.cornerRadius
        )
        backgroundColor.setFill()
        path.fill()
      }
    }
  }

  private func codeBlockRect(for range: NSRange, style: CodeBlockStyle) -> NSRect? {
    if let textLayoutManager = textLayoutManager,
       let textContentManager = textLayoutManager.textContentManager
    {
      let documentRange = textContentManager.documentRange
      guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
            let endLocation = textContentManager.location(startLocation, offsetBy: range.length)
      else { return nil }
      guard let textRange = NSTextRange(location: startLocation, end: endLocation) else { return nil }
      var unionRect: NSRect?
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .standard,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += textContainerInset.width
        adjusted.origin.y += textContainerInset.height
        unionRect = unionRect?.union(adjusted) ?? adjusted
        return true
      }
      if var rect = unionRect {
        rect.origin.x -= style.textInsetLeft
        rect.size.width += style.textInsetLeft + style.textInsetRight
        rect.origin.y -= style.verticalPadding
        rect.size.height += style.verticalPadding * 2
        let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
        let clipped = rect.intersection(insetBounds)
        return clipped.isNull ? nil : clipped
      }
      return nil
    }

    guard let layoutManager, let textContainer else { return nil }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return nil }

    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    rect.origin.x += textContainerInset.width
    rect.origin.y += textContainerInset.height

    var padded = rect
    padded.origin.x -= style.textInsetLeft
    padded.size.width += style.textInsetLeft + style.textInsetRight
    padded.origin.y -= style.verticalPadding
    padded.size.height += style.verticalPadding * 2

    let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
    let clipped = padded.intersection(insetBounds)
    return clipped.isNull ? nil : clipped
  }

  private func inlineCodeRects(for range: NSRange, style: CodeBlockStyle) -> [NSRect] {
    if let textLayoutManager = textLayoutManager,
       let textContentManager = textLayoutManager.textContentManager
    {
      let documentRange = textContentManager.documentRange
      guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
            let endLocation = textContentManager.location(startLocation, offsetBy: range.length),
            let textRange = NSTextRange(location: startLocation, end: endLocation)
      else { return [] }

      var rects: [NSRect] = []
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .selection,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        if let adjustedRect = self.adjustedInlineCodeRect(for: segmentRect, style: style) {
          rects.append(adjustedRect)
        }
        return true
      }
      return mergeInlineCodeRects(rects)
    }

    guard let layoutManager, let textContainer else { return [] }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return [] }

    var rects: [NSRect] = []
    layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphRange,
      withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: textContainer
    ) { rect, _ in
      var adjusted = rect
      adjusted.origin.x += self.textContainerInset.width
      adjusted.origin.y += self.textContainerInset.height
      if let adjustedRect = self.adjustedInlineCodeRect(for: adjusted, style: style) {
        rects.append(adjustedRect)
      }
    }

    return mergeInlineCodeRects(rects)
  }

  private func adjustedInlineCodeRect(for rect: NSRect, style: CodeBlockStyle) -> NSRect? {
    guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }

    var padded = rect
    padded.origin.x -= style.textInsetLeft
    padded.size.width += style.textInsetLeft + style.textInsetRight
    padded.origin.y -= style.verticalPadding
    padded.size.height += style.verticalPadding * 2

    let insetBounds = bounds.insetBy(dx: style.blockHorizontalInset, dy: 0)
    let clipped = padded.intersection(insetBounds)
    return clipped.isNull ? nil : clipped
  }

  private func mergeInlineCodeRects(_ rects: [NSRect]) -> [NSRect] {
    let tolerance: CGFloat = 1
    let sortedRects = rects.sorted { lhs, rhs in
      if abs(lhs.minY - rhs.minY) > tolerance {
        return lhs.minY < rhs.minY
      }
      return lhs.minX < rhs.minX
    }

    var mergedRects: [NSRect] = []
    for rect in sortedRects {
      guard var lastRect = mergedRects.last else {
        mergedRects.append(rect)
        continue
      }

      let sameLine = abs(lastRect.minY - rect.minY) <= tolerance
        && abs(lastRect.height - rect.height) <= tolerance
      let overlapsOrTouches = rect.minX <= lastRect.maxX + tolerance

      if sameLine && overlapsOrTouches {
        lastRect = lastRect.union(rect)
        mergedRects[mergedRects.count - 1] = lastRect
      } else {
        mergedRects.append(rect)
      }
    }

    return mergedRects
  }
}

extension NSTextView {
  func setMessageAttributedString(
    _ attributedString: NSAttributedString,
    isRtl: Bool,
    layoutSize: CGSize,
    useTextKit2: Bool
  ) {
    let direction: NSWritingDirection = isRtl ? .rightToLeft : .leftToRight
    let alignment: NSTextAlignment = isRtl ? .right : .left
    let displayedString = attributedString.messageApplyingParagraphDirection(
      direction: direction,
      alignment: alignment
    )

    textStorage?.setAttributedString(displayedString)
    (self as? MessageTextView)?.invalidateListSelectionRects()
    self.alignment = alignment

    let fullRange = NSRange(location: 0, length: displayedString.length)
    if fullRange.length > 0 {
      setAlignment(alignment, range: fullRange)
      setBaseWritingDirection(direction, range: fullRange)
    }

    textContainer?.size = layoutSize
    if !useTextKit2, let textContainer {
      layoutManager?.ensureLayout(for: textContainer)
    }
  }
}

private extension NSAttributedString {
  func messageApplyingParagraphDirection(
    direction: NSWritingDirection,
    alignment: NSTextAlignment
  ) -> NSAttributedString {
    guard length > 0 else { return self }

    let result = NSMutableAttributedString(attributedString: self)
    let fullRange = NSRange(location: 0, length: length)
    result.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
      let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
        ?? (NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle)
      style.baseWritingDirection = direction
      style.alignment = alignment
      result.addAttribute(.paragraphStyle, value: style, range: range)
    }
    return result
  }
}
