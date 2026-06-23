import AppKit
import Combine
import GRDB
import InlineKit
import InlineProtocol
import Nuke
#if canImport(QuickLookUI)
import QuickLookUI
#elseif canImport(QuickLook)
import QuickLook
#endif
import UniformTypeIdentifiers

private struct RichCopyPayload {
  let selected: String
  let selectedAttributed: NSAttributedString?
  let all: String
}

private typealias RichCopyTextProvider = () -> RichCopyPayload

#if DEBUG
struct RichRendererReuseDiagnostics: Equatable {
  var rootConfigures = 0
  var rootBlocksCreated = 0
  var rootBlocksReused = 0
  var blockViewsCreated = 0
  var blockViewsReused = 0
  var blockViewsRemoved = 0
  var blockConfigures = 0
  var blockRebuilds = 0
  var blockSignatureSkips = 0
  var nestedBlocksCreated = 0
  var nestedBlocksReused = 0
  var nestedBlocksRemoved = 0
  var textViewsCreated = 0
  var textViewsReused = 0
  var textViewsRemoved = 0
  var mediaViewsCreated = 0
  var mediaViewsReused = 0
  var mediaViewsReplaced = 0
  var mediaViewsRemoved = 0
  var tableContainersCreated = 0
  var tableContainersReused = 0
  var tableContainersRemoved = 0
  var chromeViewsCreated = 0
  var chromeViewsReused = 0
  var chromeViewsRemoved = 0

  var totalCreated: Int {
    rootBlocksCreated + blockViewsCreated + nestedBlocksCreated + textViewsCreated + mediaViewsCreated + tableContainersCreated + chromeViewsCreated
  }

  var totalReused: Int {
    rootBlocksReused + blockViewsReused + nestedBlocksReused + textViewsReused + mediaViewsReused + tableContainersReused + chromeViewsReused + blockSignatureSkips
  }

  var compactSummary: String {
    "Reuse: cfg \(rootConfigures), created \(totalCreated), reused \(totalReused), rebuilt \(blockRebuilds), skipped \(blockSignatureSkips), text \(textViewsReused)/\(textViewsCreated), media \(mediaViewsReused)/\(mediaViewsCreated), table \(tableContainersReused)/\(tableContainersCreated), chrome \(chromeViewsReused)/\(chromeViewsCreated)"
  }

  mutating func merge(_ other: RichRendererReuseDiagnostics) {
    rootConfigures += other.rootConfigures
    rootBlocksCreated += other.rootBlocksCreated
    rootBlocksReused += other.rootBlocksReused
    blockViewsCreated += other.blockViewsCreated
    blockViewsReused += other.blockViewsReused
    blockViewsRemoved += other.blockViewsRemoved
    blockConfigures += other.blockConfigures
    blockRebuilds += other.blockRebuilds
    blockSignatureSkips += other.blockSignatureSkips
    nestedBlocksCreated += other.nestedBlocksCreated
    nestedBlocksReused += other.nestedBlocksReused
    nestedBlocksRemoved += other.nestedBlocksRemoved
    textViewsCreated += other.textViewsCreated
    textViewsReused += other.textViewsReused
    textViewsRemoved += other.textViewsRemoved
    mediaViewsCreated += other.mediaViewsCreated
    mediaViewsReused += other.mediaViewsReused
    mediaViewsReplaced += other.mediaViewsReplaced
    mediaViewsRemoved += other.mediaViewsRemoved
    tableContainersCreated += other.tableContainersCreated
    tableContainersReused += other.tableContainersReused
    tableContainersRemoved += other.tableContainersRemoved
    chromeViewsCreated += other.chromeViewsCreated
    chromeViewsReused += other.chromeViewsReused
    chromeViewsRemoved += other.chromeViewsRemoved
  }
}

struct RichRendererSpoilerDiagnostics: Equatable {
  var textLeafCount = 0
  var spoilerRangeCount = 0
  var hiddenRangeCount = 0
  var revealedRangeCount = 0
  var hiddenLinkRangeCount = 0
  var revealedLinkRangeCount = 0
  var spoilerHitTargetCount = 0
  var spoilerHitTargetMissCount = 0
  var linkHitTargetCount = 0
  var hiddenLinkRevealPriorityCount = 0
  var spoilerIDs: Set<String> = []
  var hiddenSpoilerIDs: Set<String> = []
  var revealedSpoilerIDs: Set<String> = []

  var compactSummary: String {
    "spoilers \(spoilerRangeCount) range(s), hidden \(hiddenRangeCount), revealed \(revealedRangeCount), hidden links \(hiddenLinkRangeCount), revealed links \(revealedLinkRangeCount), hit \(spoilerHitTargetCount)/\(spoilerHitTargetCount + spoilerHitTargetMissCount), link hit \(linkHitTargetCount), reveal links \(hiddenLinkRevealPriorityCount), ids \(spoilerIDs.count)"
  }

  mutating func merge(_ other: RichRendererSpoilerDiagnostics) {
    textLeafCount += other.textLeafCount
    spoilerRangeCount += other.spoilerRangeCount
    hiddenRangeCount += other.hiddenRangeCount
    revealedRangeCount += other.revealedRangeCount
    hiddenLinkRangeCount += other.hiddenLinkRangeCount
    revealedLinkRangeCount += other.revealedLinkRangeCount
    spoilerHitTargetCount += other.spoilerHitTargetCount
    spoilerHitTargetMissCount += other.spoilerHitTargetMissCount
    linkHitTargetCount += other.linkHitTargetCount
    hiddenLinkRevealPriorityCount += other.hiddenLinkRevealPriorityCount
    spoilerIDs.formUnion(other.spoilerIDs)
    hiddenSpoilerIDs.formUnion(other.hiddenSpoilerIDs)
    revealedSpoilerIDs.formUnion(other.revealedSpoilerIDs)
  }
}

struct RichRendererSpoilerClickDiagnostics: Equatable {
  var hiddenClickAttempted = false
  var hiddenClickChangedState = false
  var hiddenClickRevealed = false
  var hiddenLinkClickAttempted = false
  var hiddenLinkClickChangedState = false
  var hiddenLinkClickRevealed = false

  var isPassing: Bool {
    hiddenClickAttempted &&
      hiddenClickChangedState &&
      hiddenClickRevealed &&
      hiddenLinkClickAttempted &&
      hiddenLinkClickChangedState &&
      hiddenLinkClickRevealed
  }

  var compactSummary: String {
    "spoiler clicks hidden attempted=\(hiddenClickAttempted), changed=\(hiddenClickChangedState), revealed=\(hiddenClickRevealed), hiddenLink attempted=\(hiddenLinkClickAttempted), changed=\(hiddenLinkClickChangedState), revealed=\(hiddenLinkClickRevealed)"
  }
}

struct RichTableWheelBehaviorDiagnostics: Equatable {
  var verticalForwarded = false
  var disabledHorizontalForwarded = false
  var horizontalHandled = false
  var shiftWheelHandled = false
  var eventCreationFailed = false

  var isPassing: Bool {
    !eventCreationFailed && verticalForwarded && disabledHorizontalForwarded && horizontalHandled && shiftWheelHandled
  }

  var compactSummary: String {
    "wheel behavior verticalForwarded=\(verticalForwarded), disabledForwarded=\(disabledHorizontalForwarded), horizontalHandled=\(horizontalHandled), shiftHandled=\(shiftWheelHandled), eventCreationFailed=\(eventCreationFailed)"
  }
}

struct RichRendererSelectionDiagnostics: Equatable {
  var visibleLeafCount = 0
  var selectedLeafCount = 0
  var selectedRangeCount = 0
  var selectedCharacterCount = 0
  var totalCharacterCount = 0

  var isPassing: Bool {
    visibleLeafCount > 1 && selectedLeafCount > 1 && selectedRangeCount >= selectedLeafCount && selectedCharacterCount > 0
  }

  var isPartialPassing: Bool {
    isPassing && totalCharacterCount > 0 && selectedCharacterCount < totalCharacterCount
  }

  var isPartialNonEmpty: Bool {
    visibleLeafCount > 0 &&
      selectedLeafCount > 0 &&
      selectedRangeCount >= selectedLeafCount &&
      selectedCharacterCount > 0 &&
      totalCharacterCount > 0 &&
      selectedCharacterCount < totalCharacterCount
  }

  var compactSummary: String {
    "selection leaves \(selectedLeafCount)/\(visibleLeafCount), ranges \(selectedRangeCount), chars \(selectedCharacterCount)"
  }

  var partialSummary: String {
    "\(compactSummary)/\(totalCharacterCount)"
  }
}
#endif

private func writeRichTextToPasteboard(_ text: String, attributed: NSAttributedString? = nil) {
  NSPasteboard.general.clearContents()
  if let attributed,
     attributed.length > 0
  {
    let pasteAttributed = readableRichCopyAttributedText(attributed)
    let range = NSRange(location: 0, length: pasteAttributed.length)
    if let data = try? pasteAttributed.data(
       from: range,
       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
     )
    {
      NSPasteboard.general.setData(data, forType: .rtf)
    }
  }
  NSPasteboard.general.setString(text, forType: .string)
}

private func readableRichCopyAttributedText(_ attributed: NSAttributedString) -> NSAttributedString {
  let copy = NSMutableAttributedString(attributedString: attributed)
  let fullRange = NSRange(location: 0, length: copy.length)
  guard fullRange.length > 0 else { return copy }

  copy.enumerateAttribute(.richSpoilerHidden, in: fullRange) { value, range, _ in
    guard (value as? Bool) == true else { return }
    copy.removeAttribute(.foregroundColor, range: range)
    copy.removeAttribute(.backgroundColor, range: range)
  }

  for key in [NSAttributedString.Key.richSpoiler, .richSpoilerID, .richSpoilerHidden, .cursor] {
    copy.removeAttribute(key, range: fullRange)
  }

  return copy
}

private func joinedAttributedText(_ parts: [NSAttributedString]) -> NSAttributedString? {
  let result = NSMutableAttributedString(string: "")
  for part in parts where part.length > 0 {
    if result.length > 0 {
      result.append(NSAttributedString(string: "\n"))
    }
    result.append(part)
  }
  return result.length > 0 ? result : nil
}

private extension NSView {
  var isRichSelectionVisibleContainer: Bool {
    var view: NSView? = self
    while let current = view {
      guard !current.isHidden,
            current.alphaValue > 0.001,
            current.bounds.width > 0,
            current.bounds.height > 0
      else { return false }

      view = current.superview
    }
    return true
  }
}

private final class RichTextSelectionCoordinator {
  private struct SelectionPoint {
    let textView: RichSpoilerTextView
    let index: Int
  }

  private struct PendingSelection {
    let anchor: SelectionPoint
    let startPoint: NSPoint
    var current: SelectionPoint
    var isActive: Bool
  }

  weak var rootView: RichMessageBlockAppKitView?

  private var pending: PendingSelection?

  func begin(from textView: RichSpoilerTextView, event: NSEvent) {
    guard event.type == .leftMouseDown, event.clickCount == 1 else { return }
    guard let rootView, let index = textView.richSelectionIndex(at: textView.convert(event.locationInWindow, from: nil)) else {
      return
    }

    rootView.clearRichTextSelection()
    let point = SelectionPoint(textView: textView, index: index)
    pending = PendingSelection(
      anchor: point,
      startPoint: rootView.convert(event.locationInWindow, from: nil),
      current: point,
      isActive: false
    )
  }

  func track(event: NSEvent) {
    guard var pending, let rootView else { return }
    guard event.type == .leftMouseDragged || event.type == .leftMouseUp else { return }
    guard let current = selectionPoint(at: event.locationInWindow) else { return }

    let point = rootView.convert(event.locationInWindow, from: nil)
    let dx = point.x - pending.startPoint.x
    let dy = point.y - pending.startPoint.y
    let didMoveEnough = (dx * dx + dy * dy) >= 16
    let didCrossTextView = current.textView !== pending.anchor.textView
    pending.current = current

    if pending.isActive || didMoveEnough || didCrossTextView {
      pending.isActive = true
      self.pending = pending
      applySelection(from: pending.anchor, to: current)
    } else {
      self.pending = pending
    }
  }

  func finishTracking() {
    defer { pending = nil }
    guard let pending, pending.isActive else { return }
    rootView?.window?.makeFirstResponder(rootView)
    applySelection(from: pending.anchor, to: pending.current)
  }

  func cancelTracking() {
    pending = nil
  }

  func selectAll() {
    guard let rootView else { return }
    let leaves = rootView.visibleTextLeaves
    guard !leaves.isEmpty else { return }

    rootView.clearRichTextSelection()
    for leaf in leaves {
      setSelection(in: leaf, start: 0, end: leaf.richTextLength)
    }
    rootView.window?.makeFirstResponder(rootView)
  }

  #if DEBUG
  func debugDragAcrossVisibleLeavesForTestBook() -> Bool {
    guard let rootView else { return false }
    let leaves = rootView.visibleTextLeaves.filter { $0.richTextLength > 0 }
    guard let first = leaves.first,
          let last = leaves.last,
          first !== last
    else { return false }

    let startPoint = debugWindowPoint(in: first, xFraction: 0.35, yFraction: 0.5)
    let endPoint = debugWindowPoint(in: last, xFraction: 0.65, yFraction: 0.5)
    guard let down = debugMouseEvent(type: .leftMouseDown, point: startPoint, clickCount: 1),
          let drag = debugMouseEvent(type: .leftMouseDragged, point: endPoint, clickCount: 1),
          let up = debugMouseEvent(type: .leftMouseUp, point: endPoint, clickCount: 1)
    else { return false }

    begin(from: first, event: down)
    track(event: drag)
    track(event: up)
    finishTracking()
    return true
  }

  private func debugWindowPoint(in textView: RichSpoilerTextView, xFraction: CGFloat, yFraction: CGFloat) -> NSPoint {
    let x = textView.bounds.minX + textView.bounds.width * xFraction
    let y = textView.bounds.minY + textView.bounds.height * yFraction
    return textView.convert(NSPoint(x: x, y: y), to: nil)
  }

  private func debugMouseEvent(type: NSEvent.EventType, point: NSPoint, clickCount: Int) -> NSEvent? {
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: rootView?.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0,
      clickCount: clickCount,
      pressure: type == .leftMouseUp ? 0 : 1
    )
  }
  #endif

  private func selectionPoint(at windowPoint: NSPoint) -> SelectionPoint? {
    guard let rootView else { return nil }
    let leaves = rootView.visibleTextLeaves
    guard !leaves.isEmpty else { return nil }

    let rootPoint = rootView.convert(windowPoint, from: nil)
    let entries = leaves.map { textView in
      (textView: textView, rect: rootView.convert(textView.bounds, from: textView))
    }

    for entry in entries where entry.rect.insetBy(dx: -2, dy: -2).contains(rootPoint) {
      let localPoint = entry.textView.convert(windowPoint, from: nil)
      let index = entry.textView.richSelectionIndex(at: localPoint) ?? fallbackIndex(for: entry.textView, at: localPoint)
      return SelectionPoint(textView: entry.textView, index: index)
    }

    guard var nearest = entries.first else { return nil }
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for entry in entries {
      let clampedX = min(max(rootPoint.x, entry.rect.minX), entry.rect.maxX)
      let clampedY = min(max(rootPoint.y, entry.rect.minY), entry.rect.maxY)
      let dx = rootPoint.x - clampedX
      let dy = rootPoint.y - clampedY
      let distance = dx * dx + dy * dy
      if distance < bestDistance {
        bestDistance = distance
        nearest = entry
      }
    }

    let localPoint = nearest.textView.convert(windowPoint, from: nil)
    let index = fallbackIndex(for: nearest.textView, at: localPoint)
    return SelectionPoint(textView: nearest.textView, index: index)
  }

  private func fallbackIndex(for textView: RichSpoilerTextView, at point: NSPoint) -> Int {
    guard textView.richTextLength > 0 else { return 0 }
    if point.y <= textView.bounds.minY { return 0 }
    if point.y >= textView.bounds.maxY { return textView.richTextLength }
    let isRTL = textView.richDirection == .directionRtl
    if point.x <= textView.bounds.minX { return isRTL ? textView.richTextLength : 0 }
    if point.x >= textView.bounds.maxX { return isRTL ? 0 : textView.richTextLength }
    return point.x < textView.bounds.midX
      ? (isRTL ? textView.richTextLength : 0)
      : (isRTL ? 0 : textView.richTextLength)
  }

  private func applySelection(from anchor: SelectionPoint, to current: SelectionPoint) {
    guard let rootView else { return }
    let leaves = rootView.visibleTextLeaves
    guard let anchorIndex = leaves.firstIndex(where: { $0 === anchor.textView }),
          let currentIndex = leaves.firstIndex(where: { $0 === current.textView })
    else { return }

    for leaf in leaves {
      leaf.clearRichSelection()
    }

    if anchorIndex == currentIndex {
      let start = min(anchor.index, current.index)
      let end = max(anchor.index, current.index)
      setSelection(in: anchor.textView, start: start, end: end)
      return
    }

    let isForward = anchorIndex < currentIndex
    let range = isForward ? anchorIndex...currentIndex : currentIndex...anchorIndex
    for index in range {
      let leaf = leaves[index]
      switch (isForward, index) {
      case (true, anchorIndex):
        setSelection(in: leaf, start: anchor.index, end: leaf.richTextLength)
      case (true, currentIndex):
        setSelection(in: leaf, start: 0, end: current.index)
      case (false, currentIndex):
        setSelection(in: leaf, start: current.index, end: leaf.richTextLength)
      case (false, anchorIndex):
        setSelection(in: leaf, start: 0, end: anchor.index)
      default:
        setSelection(in: leaf, start: 0, end: leaf.richTextLength)
      }
    }
  }

  private func setSelection(in textView: RichSpoilerTextView, start: Int, end: Int) {
    let length = textView.richTextLength
    let safeStart = min(max(0, start), length)
    let safeEnd = min(max(0, end), length)
    guard safeEnd > safeStart else { return }
    textView.selectedRanges = [NSValue(range: NSRange(location: safeStart, length: safeEnd - safeStart))]
  }
}

private extension RichMessageBlockStyle {
  var appKitReuseSignature: String {
    [
      "\(baseFont.fontName):\(baseFont.pointSize)",
      "\(codeFont.fontName):\(codeFont.pointSize)",
      Self.colorSignature(primary),
      Self.colorSignature(secondary),
      Self.colorSignature(link),
      Self.colorSignature(border),
      Self.colorSignature(fill),
      Self.colorSignature(codeFill),
      Self.colorSignature(accent),
    ].joined(separator: ";")
  }

  static func colorSignature(_ color: NSColor) -> String {
    guard let converted = color.usingColorSpace(.deviceRGB) else {
      return color.description
    }
    return [
      converted.redComponent,
      converted.greenComponent,
      converted.blueComponent,
      converted.alphaComponent,
    ].map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
  }
}

final class RichMessageBlockAppKitView: NSView {
  private var blocksView: RichBlocksAppKitView?
  private let selectionCoordinator = RichTextSelectionCoordinator()
  private var copyableRichText = ""
  private var selectionIdentity: String?
  private var scrollState: MessageListScrollState = .idle
  #if DEBUG
  private var debugDiagnostics = RichRendererReuseDiagnostics()
  #endif

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    selectionCoordinator.rootView = self
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
    for subview in subviews.reversed() {
      let subviewPoint = convert(point, to: subview)
      guard subview.bounds.contains(subviewPoint),
            let hit = subview.hitTest(subviewPoint)
      else { continue }
      return hit
    }
    return self
  }

  func configure(
    richText: RichMessage,
    layout: RichMessageLayoutPlan,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot,
    selectionIdentity: String? = nil,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?
  ) {
    #if DEBUG
    debugDiagnostics.rootConfigures += 1
    #endif

    if let selectionIdentity, self.selectionIdentity != selectionIdentity {
      clearRichTextSelection()
      self.selectionIdentity = selectionIdentity
    }

    copyableRichText = richText.fallbackText
    let copyTextProvider: RichCopyTextProvider = { [weak self] in
      guard let self else {
        return RichCopyPayload(selected: "", selectedAttributed: nil, all: "")
      }
      return self.richCopyPayload
    }

    let view: RichBlocksAppKitView
    if let existing = blocksView {
      #if DEBUG
      debugDiagnostics.rootBlocksReused += 1
      #endif
      view = existing
      view.configure(
        layout: layout.root,
        style: style,
        state: state,
        inheritedDirection: richText.direction,
        scrollState: scrollState,
        stateDidChange: stateDidChange,
        copyTextProvider: copyTextProvider,
        selectionCoordinator: selectionCoordinator
      )
    } else {
      view = RichBlocksAppKitView(
        layout: layout.root,
        style: style,
        state: state,
        inheritedDirection: richText.direction,
        scrollState: scrollState,
        stateDidChange: stateDidChange,
        copyTextProvider: copyTextProvider,
        selectionCoordinator: selectionCoordinator
      )
      addSubview(view)
      blocksView = view
      #if DEBUG
      debugDiagnostics.rootBlocksCreated += 1
      #endif
    }
    view.frame = CGRect(origin: .zero, size: layout.size)
  }

  func setScrollState(_ state: MessageListScrollState) {
    scrollState = state
    blocksView?.setScrollState(state)
  }

  func resetInteractionStateForReuse() {
    selectionCoordinator.cancelTracking()
    clearRichTextSelection()
    selectionIdentity = nil
    copyableRichText = ""
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    makeRichCopyMenu()
  }

  private var selectedRichText: String {
    blocksView?.selectedPlainText ?? ""
  }

  private var selectedRichAttributedText: NSAttributedString? {
    blocksView?.selectedAttributedText
  }

  private var richCopyPayload: RichCopyPayload {
    RichCopyPayload(
      selected: selectedRichText,
      selectedAttributed: selectedRichAttributedText,
      all: copyableRichText
    )
  }

  fileprivate var orderedTextLeaves: [RichSpoilerTextView] {
    blocksView?.orderedTextLeaves ?? []
  }

  fileprivate var visibleTextLeaves: [RichSpoilerTextView] {
    orderedTextLeaves.filter { $0.isRichSelectionVisible && $0.richTextLength > 0 }
  }

  #if DEBUG
  func debugSpoilerDiagnosticsForTestBook() -> RichRendererSpoilerDiagnostics {
    var diagnostics = RichRendererSpoilerDiagnostics()
    for textView in orderedTextLeaves {
      diagnostics.merge(textView.debugSpoilerDiagnosticsForTestBook())
    }
    return diagnostics
  }

  func debugClickFirstHiddenSpoilerForTestBook(requireLink: Bool = false) -> String? {
    for textView in orderedTextLeaves {
      if let id = textView.debugClickFirstHiddenSpoilerForTestBook(requireLink: requireLink) {
        return id
      }
    }
    return nil
  }

  func debugMouseDownFirstHiddenSpoilerForTestBook(requireLink: Bool = false) -> String? {
    for textView in orderedTextLeaves {
      if let id = textView.debugMouseDownFirstHiddenSpoilerForTestBook(requireLink: requireLink) {
        return id
      }
    }
    return nil
  }
  #endif

  fileprivate func clearRichTextSelection() {
    for textView in orderedTextLeaves {
      textView.clearRichSelection()
    }
  }

  private func makeRichCopyMenu() -> NSMenu? {
    let selected = selectedRichText
    let full = copyableRichText
    guard !selected.isEmpty || !full.isEmpty else { return nil }

    let menu = NSMenu()
    if !selected.isEmpty {
      let copy = NSMenuItem(title: "Copy Selected Rich Text", action: #selector(copySelectedRichText), keyEquivalent: "")
      copy.target = self
      copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Selected Rich Text")
      menu.addItem(copy)
    }

    if !full.isEmpty {
      let selectAll = NSMenuItem(title: "Select All Rich Text", action: #selector(selectAllRichTextFromMenu), keyEquivalent: "")
      selectAll.target = self
      selectAll.image = NSImage(systemSymbolName: "selection.pin.in.out", accessibilityDescription: "Select All Rich Text")
      menu.addItem(selectAll)

      let copy = NSMenuItem(title: "Copy Rich Message Text", action: #selector(copyRichMessageText), keyEquivalent: "")
      copy.target = self
      copy.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: "Copy Rich Message Text")
      menu.addItem(copy)
    }
    return menu
  }

  @objc private func selectAllRichTextFromMenu() {
    selectionCoordinator.selectAll()
  }

  @objc(selectAll:) private func selectAllRichText(_: Any?) {
    selectionCoordinator.selectAll()
  }

  @objc private func copySelectedRichText() {
    let selected = selectedRichText
    guard !selected.isEmpty else { return }
    writeRichTextToPasteboard(selected, attributed: selectedRichAttributedText)
  }

  @objc private func copyRichMessageText() {
    guard !copyableRichText.isEmpty else { return }
    writeRichTextToPasteboard(copyableRichText)
  }

  @objc(copy:) private func copyRichTextSelection(_: Any?) {
    let selected = selectedRichText
    guard !selected.isEmpty else { return }
    writeRichTextToPasteboard(selected, attributed: selectedRichAttributedText)
  }

  #if DEBUG
  func debugSelectAllAndCopyRichTextForTestBook() {
    selectionCoordinator.selectAll()
    copyRichTextSelection(nil)
  }

  func debugSelectAllRichTextCopySnapshotForTestBook() -> (text: String, hasRTF: Bool) {
    selectionCoordinator.selectAll()
    if let firstLeaf = visibleTextLeaves.first {
      window?.makeFirstResponder(firstLeaf)
    }
    let attributed = selectedRichAttributedText
    let hasRTF: Bool
    if let attributed, attributed.length > 0 {
      let range = NSRange(location: 0, length: attributed.length)
      hasRTF = (try? readableRichCopyAttributedText(attributed).data(
        from: range,
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
      )) != nil
    } else {
      hasRTF = false
    }
    return (selectedRichText, hasRTF)
  }

  func debugSelectAllRichTextForTestBook() {
    selectionCoordinator.selectAll()
    if let firstLeaf = visibleTextLeaves.first {
      window?.makeFirstResponder(firstLeaf)
    }
  }

  func debugDragSelectRichTextForTestBook() -> Bool {
    let didStart = selectionCoordinator.debugDragAcrossVisibleLeavesForTestBook()
    if let firstSelectedLeaf = visibleTextLeaves.first(where: { textView in
      textView.selectedRanges.contains { value in
        let range = value.rangeValue
        return range.location != NSNotFound && range.length > 0
      }
    }) {
      window?.makeFirstResponder(firstSelectedLeaf)
    }
    return didStart
  }

  func debugSelectedRichTextForTestBook() -> String {
    selectedRichText
  }

  func debugSelectionDiagnosticsForTestBook() -> RichRendererSelectionDiagnostics {
    var diagnostics = RichRendererSelectionDiagnostics()
    for textView in visibleTextLeaves {
      diagnostics.visibleLeafCount += 1
      diagnostics.totalCharacterCount += textView.richTextLength
      let ranges = textView.selectedRanges.compactMap { value -> NSRange? in
        let range = value.rangeValue
        guard range.location != NSNotFound,
              range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= textView.richTextLength
        else { return nil }
        return range
      }
      guard !ranges.isEmpty else { continue }
      diagnostics.selectedLeafCount += 1
      diagnostics.selectedRangeCount += ranges.count
      diagnostics.selectedCharacterCount += ranges.reduce(0) { $0 + $1.length }
    }
    return diagnostics
  }

  func debugReuseDiagnosticsForTestBook() -> RichRendererReuseDiagnostics {
    var diagnostics = debugDiagnostics
    blocksView?.appendDebugDiagnostics(to: &diagnostics)
    return diagnostics
  }

  func debugContextMenuTitlesForTestBook() -> [String] {
    var titles: [String] = []
    collectDebugContextMenuTitles(in: self, into: &titles)
    return titles.filter { !$0.isEmpty }
  }

  func debugRichMediaScrollSnapshotForTestBook() -> RichMediaScrollDebugSnapshot {
    blocksView?.debugRichMediaScrollSnapshotForTestBook() ?? RichMediaScrollDebugSnapshot()
  }

  func debugRichMediaClickSnapshotForTestBook() -> RichMediaClickDebugSnapshot {
    blocksView?.debugRichMediaClickSnapshotForTestBook() ?? RichMediaClickDebugSnapshot()
  }

  func debugCopyableBlockSnapshotsForTestBook() -> [RichCopyableBlockDebugSnapshot] {
    blocksView?.debugCopyableBlockSnapshotsForTestBook() ?? []
  }

  func debugContextCopyActionSnapshotsForTestBook() -> [RichContextCopyActionDebugSnapshot] {
    var snapshots: [RichContextCopyActionDebugSnapshot] = []
    collectDebugContextCopyActionSnapshots(in: self, into: &snapshots)
    return snapshots
  }

  private func collectDebugContextMenuTitles(in view: NSView, into titles: inout [String]) {
    if let event = debugMenuEvent(for: view),
       let menu = view.menu(for: event)
    {
      titles.append(
        contentsOf: menu.items.compactMap { item in
          guard !item.isSeparatorItem, !item.title.isEmpty else { return nil }
          return item.title
        }
      )
    }

    for subview in view.subviews {
      collectDebugContextMenuTitles(in: subview, into: &titles)
    }
  }

  private func collectDebugContextCopyActionSnapshots(
    in view: NSView,
    into snapshots: inout [RichContextCopyActionDebugSnapshot]
  ) {
    if let textView = view as? RichSpoilerTextView,
       let snapshot = textView.debugCopyFirstLinkForTestBook()
    {
      snapshots.append(snapshot)
    }
    if let mediaView = view as? RichMediaAppKitView,
       let snapshot = mediaView.debugCopySourceForTestBook()
    {
      snapshots.append(snapshot)
    }
    if let audioView = view as? RichAudioAppKitView,
       let snapshot = audioView.debugCopySourceForTestBook()
    {
      snapshots.append(snapshot)
    }
    if let overlay = view as? RichURLCardOverlay {
      snapshots.append(overlay.debugCopyURLForTestBook())
    }
    if let cell = view as? RichTableCellBackground {
      let hitPoint = cell.debugBackgroundHitPointForTestBook()
      let rootPoint: NSPoint
      if cell.window != nil, window != nil {
        rootPoint = convert(cell.convert(hitPoint, to: nil), from: nil)
      } else {
        rootPoint = cell.convert(hitPoint, to: self)
      }
      let hitView = hitTest(rootPoint)
      let sourceHitTested = hitView === cell
      let sourceHitView = hitView.map { String(describing: type(of: $0)) } ?? "nil"
      if let snapshot = cell.debugCopyCellForTestBook(
        sourceHitTested: sourceHitTested,
        sourceHitView: sourceHitView
      ) {
        snapshots.append(snapshot)
      }
    }

    for subview in view.subviews {
      collectDebugContextCopyActionSnapshots(in: subview, into: &snapshots)
    }
  }

  private func debugMenuEvent(for view: NSView) -> NSEvent? {
    let localPoint = NSPoint(
      x: view.bounds.isEmpty ? 0 : view.bounds.midX,
      y: view.bounds.isEmpty ? 0 : view.bounds.midY
    )
    let windowPoint = view.window == nil ? localPoint : view.convert(localPoint, to: nil)
    return NSEvent.mouseEvent(
      with: .rightMouseDown,
      location: windowPoint,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )
  }
  #endif
}

private final class RichBlocksAppKitView: NSView {
  private var layout: RichBlocksLayoutPlan
  private var style: RichMessageBlockStyle
  private var state: RichMessageBlockStateSnapshot
  private var inheritedDirection: RichDirection
  private var scrollState: MessageListScrollState
  private var stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?
  private var copyTextProvider: RichCopyTextProvider?
  private weak var selectionCoordinator: RichTextSelectionCoordinator?
  private var blockViewsByID: [String: RichBlockAppKitView] = [:]
  #if DEBUG
  private var debugDiagnostics = RichRendererReuseDiagnostics()
  #endif

  override var isFlipped: Bool { true }

  init(
    layout: RichBlocksLayoutPlan,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot,
    inheritedDirection: RichDirection,
    scrollState: MessageListScrollState,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?,
    copyTextProvider: RichCopyTextProvider?,
    selectionCoordinator: RichTextSelectionCoordinator?
  ) {
    self.layout = layout
    self.style = style
    self.state = state
    self.inheritedDirection = inheritedDirection
    self.scrollState = scrollState
    self.stateDidChange = stateDidChange
    self.copyTextProvider = copyTextProvider
    self.selectionCoordinator = selectionCoordinator

    super.init(frame: CGRect(origin: .zero, size: layout.size))
    wantsLayer = true
    reconcileBlockViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
    for subview in subviews.reversed() {
      let subviewPoint = convert(point, to: subview)
      guard subview.bounds.contains(subviewPoint),
            let hit = subview.hitTest(subviewPoint)
      else { continue }
      return hit
    }
    return nil
  }

  func configure(
    layout: RichBlocksLayoutPlan,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot,
    inheritedDirection: RichDirection,
    scrollState: MessageListScrollState,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?,
    copyTextProvider: RichCopyTextProvider?,
    selectionCoordinator: RichTextSelectionCoordinator?
  ) {
    self.layout = layout
    self.style = style
    self.state = state
    self.inheritedDirection = inheritedDirection
    self.scrollState = scrollState
    self.stateDidChange = stateDidChange
    self.copyTextProvider = copyTextProvider
    self.selectionCoordinator = selectionCoordinator
    frame.size = layout.size
    reconcileBlockViews()
  }

  func setScrollState(_ state: MessageListScrollState) {
    scrollState = state
    for view in blockViewsByID.values {
      view.setScrollState(state)
    }
  }

  var selectedPlainText: String {
    layout.items
      .compactMap { blockViewsByID[$0.id]?.selectedPlainText }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  var selectedAttributedText: NSAttributedString? {
    joinedAttributedText(
      layout.items.compactMap { blockViewsByID[$0.id]?.selectedAttributedText }
    )
  }

  fileprivate var orderedTextLeaves: [RichSpoilerTextView] {
    layout.items.flatMap { blockViewsByID[$0.id]?.orderedTextLeaves ?? [] }
  }

  private func reconcileBlockViews() {
    var liveIDs = Set<String>()
    for item in layout.items {
      liveIDs.insert(item.id)
      let existing = blockViewsByID[item.id]
      let view = existing ?? RichBlockAppKitView()
      #if DEBUG
      if existing == nil {
        debugDiagnostics.blockViewsCreated += 1
      } else {
        debugDiagnostics.blockViewsReused += 1
      }
      #endif
      blockViewsByID[item.id] = view
      view.configure(
        item: item,
        style: style,
        state: state,
        inheritedDirection: inheritedDirection,
        scrollState: scrollState,
        stateDidChange: stateDidChange,
        copyTextProvider: copyTextProvider,
        selectionCoordinator: selectionCoordinator
      )
      view.frame = item.frame
      if view.superview == nil {
        addSubview(view)
      }
    }

    let staleIDs = blockViewsByID.keys.filter { !liveIDs.contains($0) }
    for id in staleIDs {
      guard let view = blockViewsByID[id] else { continue }
      view.removeFromSuperview()
      blockViewsByID[id] = nil
      #if DEBUG
      debugDiagnostics.blockViewsRemoved += 1
      #endif
    }
  }

  #if DEBUG
  fileprivate func appendDebugDiagnostics(to diagnostics: inout RichRendererReuseDiagnostics) {
    diagnostics.merge(debugDiagnostics)
    for view in blockViewsByID.values {
      view.appendDebugDiagnostics(to: &diagnostics)
    }
  }

  fileprivate func debugRichMediaScrollSnapshotForTestBook() -> RichMediaScrollDebugSnapshot {
    var snapshot = RichMediaScrollDebugSnapshot()
    for item in layout.items {
      snapshot.merge(blockViewsByID[item.id]?.debugRichMediaScrollSnapshotForTestBook() ?? RichMediaScrollDebugSnapshot())
    }
    return snapshot
  }

  fileprivate func debugRichMediaClickSnapshotForTestBook() -> RichMediaClickDebugSnapshot {
    var snapshot = RichMediaClickDebugSnapshot()
    for item in layout.items {
      snapshot.merge(blockViewsByID[item.id]?.debugRichMediaClickSnapshotForTestBook() ?? RichMediaClickDebugSnapshot())
    }
    return snapshot
  }

  fileprivate func debugCopyableBlockSnapshotsForTestBook() -> [RichCopyableBlockDebugSnapshot] {
    layout.items.flatMap { item in
      blockViewsByID[item.id]?.debugCopyableBlockSnapshotsForTestBook() ?? []
    }
  }
  #endif
}

private final class RichBlockAppKitView: NSView {
  private var item: RichBlockLayoutItem!
  private var style: RichMessageBlockStyle!
  private var state: RichMessageBlockStateSnapshot = .initial
  private var inheritedDirection: RichDirection = .directionUnspecified
  private var scrollState: MessageListScrollState = .idle
  private var stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?
  private var copyTextProvider: RichCopyTextProvider?
  private weak var selectionCoordinator: RichTextSelectionCoordinator?
  private var copyableBlockText = ""
  private var copyableBlockMenuTitle = "Copy"
  private var renderSignature: String?
  private var nestedBlocksByKey: [String: RichBlocksAppKitView] = [:]
  private var liveNestedBlockKeys = Set<String>()
  private var textViewsByKey: [String: RichSpoilerTextView] = [:]
  private var liveTextViewKeys = Set<String>()
  private var mediaViewsByKey: [String: (signature: String, view: NSView)] = [:]
  private var liveMediaViewKeys = Set<String>()
  private var tableContainersByKey: [String: (scroll: RichHorizontalScrollView, content: RichFlippedView)] = [:]
  private var liveTableContainerKeys = Set<String>()
  private var chromeViewsByKey: [String: NSView] = [:]
  private var liveChromeViewKeys = Set<String>()
  private var contentOrderByKey: [String: Int] = [:]
  private var textViewKeysByID: [ObjectIdentifier: String] = [:]
  private var nestedBlockKeysByID: [ObjectIdentifier: String] = [:]
  private var contentContainerKeysByID: [ObjectIdentifier: String] = [:]
  private var nextContentOrder = 0
  #if DEBUG
  private var debugDiagnostics = RichRendererReuseDiagnostics()
  #endif

  override var isFlipped: Bool { true }

  override init(frame: CGRect = .zero) {
    super.init(frame: frame)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
    for subview in subviews.reversed() {
      let subviewPoint = convert(point, to: subview)
      guard subview.bounds.contains(subviewPoint) else { continue }
      if let hitView = subview.hitTest(subviewPoint) {
        return hitView
      }
    }
    return nil
  }

  func configure(
    item: RichBlockLayoutItem,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot,
    inheritedDirection: RichDirection,
    scrollState: MessageListScrollState,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)?,
    copyTextProvider: RichCopyTextProvider?,
    selectionCoordinator: RichTextSelectionCoordinator?
  ) {
    #if DEBUG
    debugDiagnostics.blockConfigures += 1
    #endif
    let nextSignature = Self.renderSignature(for: item, style: style, state: state)
    self.item = item
    self.style = style
    self.state = state
    self.inheritedDirection = inheritedDirection
    self.scrollState = scrollState
    self.stateDidChange = stateDidChange
    self.copyTextProvider = copyTextProvider
    self.selectionCoordinator = selectionCoordinator
    frame.size = item.frame.size
    guard renderSignature != nextSignature else {
      #if DEBUG
      debugDiagnostics.blockSignatureSkips += 1
      #endif
      setScrollState(scrollState)
      return
    }
    #if DEBUG
    debugDiagnostics.blockRebuilds += 1
    #endif
    renderSignature = nextSignature
    resetForReuse()
    liveNestedBlockKeys.removeAll()
    liveTextViewKeys.removeAll()
    liveMediaViewKeys.removeAll()
    liveTableContainerKeys.removeAll()
    liveChromeViewKeys.removeAll()
    build()
    pruneStaleNestedBlocks()
    pruneStaleTextViews()
    pruneStaleMediaViews()
    pruneStaleTableContainers()
    pruneStaleChromeViews()
  }

  func setScrollState(_ state: MessageListScrollState) {
    scrollState = state
    for view in mediaViewsByKey.values {
      (view.view as? RichMediaAppKitView)?.setScrollState(state)
    }
    for view in nestedBlocksByKey.values {
      view.setScrollState(state)
    }
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    guard !copyableBlockText.isEmpty else { return nil }
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: copyableBlockMenuTitle, action: #selector(copyBlockText), keyEquivalent: ""))
    menu.items.last?.target = self
    return menu
  }

  var selectedPlainText: String {
    selectedPlainText(in: self)
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  var selectedAttributedText: NSAttributedString? {
    joinedAttributedText(selectedAttributedText(in: self))
  }

  fileprivate var orderedTextLeaves: [RichSpoilerTextView] {
    orderedTextLeaves(in: self)
  }

  private func selectedPlainText(in view: NSView) -> [String] {
    guard view.isRichSelectionVisibleContainer else { return [] }

    return orderedSubviews(in: view).flatMap { subview -> [String] in
      if let textView = subview as? RichSpoilerTextView {
        guard textView.isRichSelectionVisible else { return [] }

        let text = textView.selectedPlainTextForRichCopy
        return text.isEmpty ? [] : [text]
      }
      if let blocksView = subview as? RichBlocksAppKitView {
        let text = blocksView.selectedPlainText
        return text.isEmpty ? [] : [text]
      }
      return selectedPlainText(in: subview)
    }
  }

  private func selectedAttributedText(in view: NSView) -> [NSAttributedString] {
    guard view.isRichSelectionVisibleContainer else { return [] }

    return orderedSubviews(in: view).flatMap { subview -> [NSAttributedString] in
      if let textView = subview as? RichSpoilerTextView,
         textView.isRichSelectionVisible,
         let text = textView.selectedAttributedTextForRichCopy
      {
        return [text]
      }
      if let blocksView = subview as? RichBlocksAppKitView,
         let text = blocksView.selectedAttributedText
      {
        return [text]
      }
      return selectedAttributedText(in: subview)
    }
  }

  private func orderedTextLeaves(in view: NSView) -> [RichSpoilerTextView] {
    orderedSubviews(in: view).flatMap { subview -> [RichSpoilerTextView] in
      if let textView = subview as? RichSpoilerTextView {
        return [textView]
      }
      if let blocksView = subview as? RichBlocksAppKitView {
        return blocksView.orderedTextLeaves
      }
      return orderedTextLeaves(in: subview)
    }
  }

  private func orderedSubviews(in view: NSView) -> [NSView] {
    view.subviews.sorted { lhs, rhs in
      let lhsOrder = contentOrder(for: lhs)
      let rhsOrder = contentOrder(for: rhs)
      if let lhsOrder, let rhsOrder, lhsOrder != rhsOrder {
        return lhsOrder < rhsOrder
      }
      if lhsOrder != nil {
        return true
      }
      if rhsOrder != nil {
        return false
      }
      if abs(lhs.frame.minY - rhs.frame.minY) > 1 {
        return lhs.frame.minY < rhs.frame.minY
      }
      return lhs.frame.minX < rhs.frame.minX
    }
  }

  private func contentOrder(for view: NSView) -> Int? {
    if let key = textViewKeysByID[ObjectIdentifier(view)] {
      return contentOrderByKey["text:\(key)"]
    }
    if let key = nestedBlockKeysByID[ObjectIdentifier(view)] {
      return contentOrderByKey["nested:\(key)"]
    }
    if let key = contentContainerKeysByID[ObjectIdentifier(view)] {
      return contentOrderByKey["container:\(key)"]
    }
    return nil
  }

  private var resolvedDirection: RichDirection {
    return item.node.block.direction == .directionUnspecified ? inheritedDirection : item.node.block.direction
  }

  private var isRTL: Bool {
    resolvedDirection == .directionRtl
  }

  private func mirrored(_ frame: CGRect, in width: CGFloat? = nil) -> CGRect {
    let containerWidth = width ?? bounds.width
    return CGRect(
      x: max(0, containerWidth - frame.maxX),
      y: frame.minY,
      width: frame.width,
      height: frame.height
    )
  }

  private func build() {
    guard item != nil, style != nil else { return }
    switch item.node.block.block {
    case let .paragraph(block):
      addText(block.text, font: style.baseFont)
    case let .heading(block):
      addText(block.text, font: headingFont(level: block.level))
    case let .list(block):
      addList(block)
    case let .listItem(block):
      addListItem(block)
    case let .quote(block):
      addQuote(block)
    case let .code(block):
      addCode(block)
    case .divider:
      addDivider()
    case let .thinking(block):
      addCollapsible(
        title: "Thinking",
        childKey: "thinking",
        defaultExpanded: !block.initiallyCollapsed,
        expanded: state.isExpanded(id: item.id, defaultExpanded: !block.initiallyCollapsed),
        fill: style.fill
      )
    case let .details(block):
      addCollapsible(
        title: block.title.renderedPlainText.isEmpty ? "Details" : block.title.renderedPlainText,
        childKey: "details",
        defaultExpanded: block.initiallyOpen,
        expanded: state.isExpanded(id: item.id, defaultExpanded: block.initiallyOpen),
        fill: style.fill
      )
    case let .photo(block):
      addMedia(kind: "Photo", media: block.media, caption: block.caption)
    case let .video(block):
      addMedia(
        kind: "Video",
        media: block.media,
        caption: block.caption,
        duration: block.hasDuration ? block.duration : nil
      )
    case let .document(block):
      addMedia(kind: "Document", media: block.media, caption: block.caption)
    case let .audio(block):
      addAudio(block)
    case let .table(block):
      addTable(block)
    case let .math(block):
      addMath(block)
    case let .map(block):
      addLabelCard(
        title: block.hasTitle ? block.title : "Map",
        subtitle: block.hasAddress ? block.address : "\(block.latitude), \(block.longitude)",
        url: block.hasOpenURL ? block.openURL : mapFallbackURL(for: block),
        height: 54
      )
      addBlockCaption(block.caption, y: 60, width: bounds.width)
    case let .embed(block):
      addEmbed(block)
    case let .embedPost(block):
      addEmbedPost(block)
    case let .linkPreview(block):
      addLinkPreview(block)
    case let .collage(block):
      addCollage(block)
    case nil:
      break
    }
  }

  private func resetForReuse() {
    subviews.forEach { $0.removeFromSuperview() }
    copyableBlockText = ""
    copyableBlockMenuTitle = "Copy"
    contentOrderByKey.removeAll()
    textViewKeysByID.removeAll()
    nestedBlockKeysByID.removeAll()
    contentContainerKeysByID.removeAll()
    nextContentOrder = 0
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.cornerRadius = 0
    layer?.borderWidth = 0
    layer?.masksToBounds = false
  }

  private func addNestedBlocks(
    layout: RichBlocksLayoutPlan,
    key: String,
    frame: CGRect,
    inheritedDirection: RichDirection
  ) {
    liveNestedBlockKeys.insert(key)
    registerContentOrder(key: "nested:\(key)")
    let view: RichBlocksAppKitView
    if let existing = nestedBlocksByKey[key] {
      #if DEBUG
      debugDiagnostics.nestedBlocksReused += 1
      #endif
      view = existing
      view.configure(
        layout: layout,
        style: style,
        state: state,
        inheritedDirection: inheritedDirection,
        scrollState: scrollState,
        stateDidChange: stateDidChange,
        copyTextProvider: copyTextProvider,
        selectionCoordinator: selectionCoordinator
      )
    } else {
      view = RichBlocksAppKitView(
        layout: layout,
        style: style,
        state: state,
        inheritedDirection: inheritedDirection,
        scrollState: scrollState,
        stateDidChange: stateDidChange,
        copyTextProvider: copyTextProvider,
        selectionCoordinator: selectionCoordinator
      )
      nestedBlocksByKey[key] = view
      #if DEBUG
      debugDiagnostics.nestedBlocksCreated += 1
      #endif
    }

    view.frame = frame
    nestedBlockKeysByID[ObjectIdentifier(view)] = key
    if view.superview == nil {
      addSubview(view)
    }
  }

  private func pruneStaleNestedBlocks() {
    let staleKeys = nestedBlocksByKey.keys.filter { !liveNestedBlockKeys.contains($0) }
    for key in staleKeys {
      if let view = nestedBlocksByKey[key] {
        nestedBlockKeysByID.removeValue(forKey: ObjectIdentifier(view))
        view.removeFromSuperview()
      }
      nestedBlocksByKey[key] = nil
      #if DEBUG
      debugDiagnostics.nestedBlocksRemoved += 1
      #endif
    }
  }

  private func addTextView(
    _ attributed: NSAttributedString,
    direction: RichDirection,
    frame: CGRect,
    key: String,
    parent: NSView? = nil,
    alignment: NSTextAlignment? = nil
  ) {
    liveTextViewKeys.insert(key)
    registerContentOrder(key: "text:\(key)")
    let existing = textViewsByKey[key]
    let textView = existing ?? RichSpoilerTextView(usingTextLayoutManager: true)
    #if DEBUG
    if existing == nil {
      debugDiagnostics.textViewsCreated += 1
    } else {
      debugDiagnostics.textViewsReused += 1
    }
    #endif
    textViewsByKey[key] = textView
    configureTextView(
      textView,
      attributed,
      direction: direction,
      frame: frame,
      alignment: alignment
    )
    textViewKeysByID[ObjectIdentifier(textView)] = key

    let container = parent ?? self
    if textView.superview !== container {
      container.addSubview(textView)
    }
  }

  private func pruneStaleTextViews() {
    let staleKeys = textViewsByKey.keys.filter { !liveTextViewKeys.contains($0) }
    for key in staleKeys {
      if let textView = textViewsByKey[key] {
        textView.clearRichSelection()
        textViewKeysByID.removeValue(forKey: ObjectIdentifier(textView))
        textView.removeFromSuperview()
      }
      textViewsByKey[key] = nil
      #if DEBUG
      debugDiagnostics.textViewsRemoved += 1
      #endif
    }
  }

  private func registerContentOrder(key: String) {
    guard contentOrderByKey[key] == nil else { return }
    contentOrderByKey[key] = nextContentOrder
    nextContentOrder += 1
  }

  private func addReusableMediaView(
    key: String,
    signature: String,
    frame: CGRect,
    makeView: () -> NSView
  ) {
    liveMediaViewKeys.insert(key)

    let view: NSView
    if let existing = mediaViewsByKey[key], existing.signature == signature {
      #if DEBUG
      debugDiagnostics.mediaViewsReused += 1
      #endif
      view = existing.view
    } else {
      if let existing = mediaViewsByKey[key] {
        existing.view.removeFromSuperview()
        #if DEBUG
        debugDiagnostics.mediaViewsReplaced += 1
        #endif
      } else {
        #if DEBUG
        debugDiagnostics.mediaViewsCreated += 1
        #endif
      }
      view = makeView()
      mediaViewsByKey[key] = (signature, view)
    }

    view.frame = frame
    (view as? RichMediaAppKitView)?.setScrollState(scrollState)
    if view.superview !== self {
      addSubview(view)
    } else {
      view.removeFromSuperview()
      addSubview(view)
    }
  }

  private func pruneStaleMediaViews() {
    let staleKeys = mediaViewsByKey.keys.filter { !liveMediaViewKeys.contains($0) }
    for key in staleKeys {
      mediaViewsByKey[key]?.view.removeFromSuperview()
      mediaViewsByKey[key] = nil
      #if DEBUG
      debugDiagnostics.mediaViewsRemoved += 1
      #endif
    }
  }

  private func reusableTableContainer(
    key: String,
    scrollFrame: CGRect,
    contentSize: CGSize,
    allowsHorizontalScroll: Bool
  ) -> (scroll: RichHorizontalScrollView, content: RichFlippedView) {
    liveTableContainerKeys.insert(key)
    registerContentOrder(key: "container:\(key)")
    let views: (scroll: RichHorizontalScrollView, content: RichFlippedView)
    if let existing = tableContainersByKey[key] {
      #if DEBUG
      debugDiagnostics.tableContainersReused += 1
      #endif
      views = existing
    } else {
      views = (
        RichHorizontalScrollView(frame: scrollFrame),
        RichFlippedView(frame: CGRect(origin: .zero, size: contentSize))
      )
      tableContainersByKey[key] = views
      #if DEBUG
      debugDiagnostics.tableContainersCreated += 1
      #endif
    }

    views.scroll.frame = scrollFrame
    views.scroll.allowsHorizontalScroll = allowsHorizontalScroll
    views.scroll.drawsBackground = false
    views.scroll.hasHorizontalScroller = allowsHorizontalScroll
    views.scroll.hasVerticalScroller = false
    views.scroll.autohidesScrollers = true

    views.content.frame = CGRect(origin: .zero, size: contentSize)
    views.content.subviews.forEach { $0.removeFromSuperview() }
    views.scroll.documentView = views.content
    contentContainerKeysByID[ObjectIdentifier(views.scroll)] = key

    if views.scroll.superview !== self {
      addSubview(views.scroll)
    }

    return views
  }

  @discardableResult
  private func reusableChromeView<View: NSView>(
    key: String,
    makeView: () -> View,
    configure: (View) -> Void
  ) -> View {
    liveChromeViewKeys.insert(key)

    let view: View
    if let existing = chromeViewsByKey[key] as? View {
      #if DEBUG
      debugDiagnostics.chromeViewsReused += 1
      #endif
      view = existing
    } else {
      if let existing = chromeViewsByKey[key] {
        existing.removeFromSuperview()
        #if DEBUG
        debugDiagnostics.chromeViewsRemoved += 1
        #endif
      }
      view = makeView()
      chromeViewsByKey[key] = view
      #if DEBUG
      debugDiagnostics.chromeViewsCreated += 1
      #endif
    }

    configure(view)
    if view.superview !== self {
      addSubview(view)
    }
    return view
  }

  private func pruneStaleTableContainers() {
    let staleKeys = tableContainersByKey.keys.filter { !liveTableContainerKeys.contains($0) }
    for key in staleKeys {
      if let views = tableContainersByKey[key] {
        contentContainerKeysByID.removeValue(forKey: ObjectIdentifier(views.scroll))
        views.scroll.removeFromSuperview()
      }
      tableContainersByKey[key] = nil
      #if DEBUG
      debugDiagnostics.tableContainersRemoved += 1
      #endif
    }
  }

  private func pruneStaleChromeViews() {
    let staleKeys = chromeViewsByKey.keys.filter { !liveChromeViewKeys.contains($0) }
    for key in staleKeys {
      chromeViewsByKey[key]?.removeFromSuperview()
      chromeViewsByKey[key] = nil
      #if DEBUG
      debugDiagnostics.chromeViewsRemoved += 1
      #endif
    }
  }

  #if DEBUG
  fileprivate func appendDebugDiagnostics(to diagnostics: inout RichRendererReuseDiagnostics) {
    diagnostics.merge(debugDiagnostics)
    for view in nestedBlocksByKey.values {
      view.appendDebugDiagnostics(to: &diagnostics)
    }
  }

  fileprivate func debugRichMediaScrollSnapshotForTestBook() -> RichMediaScrollDebugSnapshot {
    var snapshot = RichMediaScrollDebugSnapshot()
    for view in mediaViewsByKey.values {
      snapshot.merge((view.view as? RichMediaAppKitView)?.debugRichMediaScrollSnapshotForTestBook() ?? RichMediaScrollDebugSnapshot())
    }
    for view in nestedBlocksByKey.values {
      snapshot.merge(view.debugRichMediaScrollSnapshotForTestBook())
    }
    return snapshot
  }

  fileprivate func debugRichMediaClickSnapshotForTestBook() -> RichMediaClickDebugSnapshot {
    var snapshot = RichMediaClickDebugSnapshot()
    for (key, view) in mediaViewsByKey {
      guard let mediaView = view.view as? RichMediaAppKitView else { continue }
      var mediaSnapshot = mediaView.debugRichMediaClickSnapshotForTestBook()
      if !mediaSnapshot.quickLookPrepareFailureDetails.isEmpty {
        mediaSnapshot.quickLookPrepareFailureDetails = mediaSnapshot.quickLookPrepareFailureDetails.map {
          "\(item.id).\(key)->\($0)"
        }
      }
      if mediaSnapshot.imageMediaViewCount > 0 {
        let point = CGPoint(x: mediaView.frame.midX, y: mediaView.frame.midY)
        let hitView = hitTest(point)
        if hitView === mediaView || hitView?.isDescendant(of: mediaView) == true {
          mediaSnapshot.imagePrimaryHitTargetCount += mediaSnapshot.imageMediaViewCount
        } else {
          mediaSnapshot.imagePrimaryHitTargetMissCount += mediaSnapshot.imageMediaViewCount
          let hitType = hitView.map { String(describing: type(of: $0)) } ?? "nil"
          let mediaPoint = convert(point, to: mediaView)
          let mediaHit = mediaView.hitTest(mediaPoint)
          let mediaHitType = mediaHit.map { String(describing: type(of: $0)) } ?? "nil"
          let attached = mediaView.superview === self ? "attached" : "detached"
          mediaSnapshot.imagePrimaryHitTargetMissDetails.append(
            "\(item.id).\(key)->\(hitType) mediaHit=\(mediaHitType) \(attached) point=\(Self.debugRect(CGRect(origin: point, size: .zero))) bounds=\(Self.debugRect(bounds)) frame=\(Self.debugRect(mediaView.frame))"
          )
        }
      }
      snapshot.merge(mediaSnapshot)
    }
    for view in nestedBlocksByKey.values {
      snapshot.merge(view.debugRichMediaClickSnapshotForTestBook())
    }
    return snapshot
  }

  private static func debugRect(_ rect: CGRect) -> String {
    "\(Int(rect.minX.rounded())):\(Int(rect.minY.rounded())):\(Int(rect.width.rounded())):\(Int(rect.height.rounded()))"
  }

  fileprivate func debugCopyableBlockSnapshotsForTestBook() -> [RichCopyableBlockDebugSnapshot] {
    var snapshots: [RichCopyableBlockDebugSnapshot] = []
    if !copyableBlockText.isEmpty {
      let actionButton = subviews.compactMap { $0 as? NSButton }
        .first { $0.action == #selector(copyBlockText) }
      var actionButtonHitTested = false
      var actionButtonCopiedText = ""
      if let actionButton {
        let center = convert(
          NSPoint(x: actionButton.bounds.midX, y: actionButton.bounds.midY),
          from: actionButton
        )
        actionButtonHitTested = hitTest(center) === actionButton
        NSPasteboard.general.clearContents()
        actionButton.performClick(nil)
        actionButtonCopiedText = NSPasteboard.general.string(forType: .string) ?? ""
      }
      copyBlockText()
      snapshots.append(
        RichCopyableBlockDebugSnapshot(
          menuTitle: copyableBlockMenuTitle,
          expectedText: copyableBlockText,
          copiedText: NSPasteboard.general.string(forType: .string) ?? "",
          actionButtonExists: actionButton != nil,
          actionButtonHitTested: actionButtonHitTested,
          actionButtonCopiedText: actionButtonCopiedText,
          actionButtonFrame: actionButton?.frame
        )
      )
    }
    for key in nestedBlocksByKey.keys.sorted() {
      snapshots.append(contentsOf: nestedBlocksByKey[key]?.debugCopyableBlockSnapshotsForTestBook() ?? [])
    }
    return snapshots
  }
  #endif

  private static func renderSignature(
    for item: RichBlockLayoutItem,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot
  ) -> String {
    let blockData = (try? item.node.block.serializedData()).map { $0.base64EncodedString() } ?? item.id
    return [
      item.id,
      "\(item.frame.width)x\(item.frame.height)",
      blockData,
      state.renderSignature(forSubtree: item.id),
      style.appKitReuseSignature,
    ].joined(separator: "|")
  }

  private static func mediaViewSignature(
    kind: String,
    media: RichMediaRef,
    duration: Int32?,
    style: RichMessageBlockStyle
  ) -> String {
    let mediaData = (try? media.serializedData()).map { $0.base64EncodedString() } ?? ""
    return [
      kind,
      "\(duration ?? -1)",
      mediaData,
      style.appKitReuseSignature,
    ].joined(separator: "|")
  }

  private static func audioViewSignature(
    block: RichAudioBlock,
    style: RichMessageBlockStyle
  ) -> String {
    let blockData = (try? block.serializedData()).map { $0.base64EncodedString() } ?? ""
    return [
      blockData,
      style.appKitReuseSignature,
    ].joined(separator: "|")
  }

  private func addText(_ nodes: [RichText], font: NSFont) {
    addTextView(
      RichTextAttributedStringBuilder.nsAttributedString(
        nodes: nodes,
        font: font,
        style: style,
        spoilerBaseID: item.id,
        state: state
      ),
      direction: resolvedDirection,
      frame: bounds,
      key: "text"
    )
  }

  private func addList(_ block: RichListBlock) {
    let metrics = RichMessageBlockSizeCalculator.listMetrics(for: block, width: bounds.width)
    var y = CGFloat(0)
    let start = block.start == 0 ? 1 : Int(block.start)

    for (index, listItem) in block.items.enumerated() {
      let childID = "\(item.id).\(index)"
      guard let child = item.children[childID] else { continue }

      let markerFrame = isRTL
        ? CGRect(x: max(0, bounds.width - metrics.markerWidth), y: y, width: metrics.markerWidth, height: min(22, child.size.height))
        : CGRect(x: 0, y: y, width: metrics.markerWidth, height: min(22, child.size.height))
      let childFrame = isRTL
        ? CGRect(x: 0, y: y, width: child.size.width, height: child.size.height)
        : CGRect(x: metrics.childX, y: y, width: child.size.width, height: child.size.height)

      addListMarker(
        text: block.ordered ? "\(start + index)." : "•",
        checked: listItem.hasChecked ? listItem.checked : nil,
        ordered: block.ordered,
        frame: markerFrame
      )

      addNestedBlocks(
        layout: child,
        key: childID,
        frame: childFrame,
        inheritedDirection: resolvedDirection
      )

      y += child.size.height + (index == block.items.count - 1 ? 0 : 6)
    }
  }

  private func addListMarker(text: String, checked: Bool?, ordered: Bool, frame: CGRect) {
    if let checked, ordered {
      let label = makeListMarkerLabel(text, alignment: isRTL ? .left : .right)
      label.frame = isRTL
        ? CGRect(x: frame.minX + 23, y: frame.minY, width: 34, height: frame.height)
        : CGRect(x: frame.minX, y: frame.minY, width: 34, height: frame.height)
      addSubview(label)

      let image = makeChecklistMarker(checked: checked)
      image.frame = isRTL
        ? CGRect(x: frame.minX, y: frame.minY + 2, width: 16, height: 16)
        : CGRect(x: frame.minX + 41, y: frame.minY + 2, width: 16, height: 16)
      addSubview(image)
      return
    }

    if let checked {
      let image = makeChecklistMarker(checked: checked)
      image.frame = CGRect(x: frame.minX + max(0, (frame.width - 16) / 2), y: frame.minY + 2, width: 16, height: 16)
      addSubview(image)
      return
    }

    let label = makeListMarkerLabel(text)
    label.frame = frame
    addSubview(label)
  }

  private func makeListMarkerLabel(_ value: String, alignment: NSTextAlignment = .right) -> NSTextField {
    let marker = NSTextField(labelWithString: value)
    marker.font = .systemFont(ofSize: style.baseFont.pointSize, weight: .medium)
    marker.textColor = style.secondary
    marker.alignment = alignment
    return marker
  }

  private func makeChecklistMarker(checked: Bool) -> NSImageView {
    let imageView = NSImageView()
    imageView.image = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: checked ? "Checked" : "Unchecked")
    imageView.contentTintColor = checked ? style.accent : style.secondary
    imageView.symbolConfiguration = .init(pointSize: max(12, style.baseFont.pointSize - 1), weight: .regular)
    return imageView
  }

  private func addListItem(_ block: RichListItemBlock) {
    guard let child = item.children["item"] else {
      addBlocks(block.blocks, key: "item", inset: .zero)
      return
    }
    addNestedBlocks(
      layout: child,
      key: "item",
      frame: CGRect(x: 0, y: 0, width: child.size.width, height: child.size.height),
      inheritedDirection: resolvedDirection
    )
  }

  private func addQuote(_ block: RichQuoteBlock) {
    let layout = item.quoteLayout ?? fallbackQuoteLayout(block)
    let ruleFrame = isRTL ? mirrored(layout.ruleFrame) : layout.ruleFrame
    let childFrame = isRTL ? mirrored(layout.childFrame) : layout.childFrame
    let buttonFrame = layout.buttonFrame.map { isRTL ? mirrored($0) : $0 }

    let rule = NSView(frame: ruleFrame)
    rule.wantsLayer = true
    rule.layer?.backgroundColor = style.accent.withAlphaComponent(0.55).cgColor
    rule.layer?.cornerRadius = RichMessageBlockSizeCalculator.quoteRuleCornerRadius
    addSubview(rule)

    if let child = item.children["quote"] {
      addNestedBlocks(
        layout: child,
        key: "quote",
        frame: childFrame,
        inheritedDirection: resolvedDirection
      )

      if let buttonFrame {
        let button = makeDisclosureButton(
          title: state.isExpanded(id: item.id, defaultExpanded: !block.initiallyCollapsed) ? "Show less" : "Show more",
          expanded: state.isExpanded(id: item.id, defaultExpanded: !block.initiallyCollapsed),
          defaultExpanded: !block.initiallyCollapsed
        )
        button.frame = buttonFrame
        addSubview(button)
      }
    }
  }

  private func fallbackQuoteLayout(_ block: RichQuoteBlock) -> RichQuoteLayoutPlan {
    let child = item.children["quote"]
    let childFrame = CGRect(x: 12, y: 0, width: child?.size.width ?? max(1, bounds.width - 12), height: child?.size.height ?? 1)
    let buttonFrame = block.expandable
      ? CGRect(x: 12, y: childFrame.maxY + 4, width: 112, height: 18)
      : nil
    let height = max(childFrame.maxY, buttonFrame?.maxY ?? 0, 1)

    return RichQuoteLayoutPlan(
      size: CGSize(width: bounds.width, height: height),
      ruleFrame: CGRect(x: 0, y: 0, width: 3, height: height),
      childFrame: childFrame,
      buttonFrame: buttonFrame
    )
  }

  private func addCode(_ block: RichCodeBlock) {
    copyableBlockText = block.text
    copyableBlockMenuTitle = "Copy Code"
    layer?.backgroundColor = style.codeFill.cgColor
    layer?.cornerRadius = 6

    let layout = RichMessageBlockSizeCalculator.codeLayout(for: block, width: bounds.width, style: style)
    if let languageFrame = layout.languageFrame {
      let label = NSTextField(labelWithString: block.language.uppercased())
      label.font = .systemFont(ofSize: 10, weight: .semibold)
      label.textColor = style.secondary
      label.frame = languageFrame
      addSubview(label)
    }

    let attributed = RichCodeBlockText.attributedString(
      block.text,
      font: style.codeFont,
      color: style.primary
    )
    addTextView(
      attributed,
      direction: .directionLtr,
      frame: layout.textFrame,
      key: "code.text"
    )

    let copy = RichCodeCopyButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code") ?? NSImage(), target: self, action: #selector(copyBlockText))
    copy.isBordered = false
    copy.frame = layout.copyFrame
    copy.identifier = NSUserInterfaceItemIdentifier("rich.code.copy")
    copy.toolTip = "Copy code"
    addSubview(copy)
  }

  private func addMath(_ block: RichMathBlock) {
    let text = block.hasFallback ? block.fallback : block.source
    copyableBlockText = text
    copyableBlockMenuTitle = "Copy Formula"

    let background = RichCardBackgroundView(frame: bounds, color: style.codeFill, cornerRadius: 6)
    addSubview(background)

    let attributed = NSAttributedString(
      string: text.isEmpty ? " " : text,
      attributes: [.font: style.codeFont, .foregroundColor: style.primary]
    )
    addTextView(
      attributed,
      direction: .directionLtr,
      frame: CGRect(x: 10, y: 10, width: max(1, bounds.width - 20), height: max(1, bounds.height - 20)),
      key: "math.text"
    )
  }

  @objc private func copyBlockText() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(copyableBlockText, forType: .string)
  }

  private func addDivider() {
    let line = NSView(frame: CGRect(x: 0, y: 4, width: bounds.width, height: 0.5))
    line.wantsLayer = true
    line.layer?.backgroundColor = style.border.withAlphaComponent(0.55).cgColor
    addSubview(line)
  }

  private func addCollapsible(
    title: String,
    childKey: String,
    defaultExpanded: Bool,
    expanded: Bool,
    fill: NSColor
  ) {
    let layout = item.collapsibleLayout ?? fallbackCollapsibleLayout(childKey: childKey, expanded: expanded)

    layer?.backgroundColor = fill.cgColor
    layer?.cornerRadius = 6

    let button = makeDisclosureButton(title: title, expanded: expanded, defaultExpanded: defaultExpanded)
    button.frame = isRTL ? mirrored(layout.buttonFrame) : layout.buttonFrame
    addSubview(button)

    guard expanded, let child = item.children[childKey] else { return }
    let childFrame = layout.childFrame ?? CGRect(x: 12, y: 35, width: child.size.width, height: child.size.height)
    addNestedBlocks(
      layout: child,
      key: childKey,
      frame: isRTL ? mirrored(childFrame) : childFrame,
      inheritedDirection: resolvedDirection
    )
  }

  private func fallbackCollapsibleLayout(childKey: String, expanded: Bool) -> RichCollapsibleLayoutPlan {
    let buttonFrame = CGRect(x: 9, y: 7, width: max(1, bounds.width - 18), height: 20)
    guard expanded, let child = item.children[childKey] else {
      return RichCollapsibleLayoutPlan(
        size: CGSize(width: bounds.width, height: 34),
        buttonFrame: buttonFrame,
        childFrame: nil
      )
    }

    let childFrame = CGRect(x: 12, y: 35, width: child.size.width, height: child.size.height)
    return RichCollapsibleLayoutPlan(
      size: CGSize(width: bounds.width, height: childFrame.maxY + 8),
      buttonFrame: buttonFrame,
      childFrame: childFrame
    )
  }

  private func addMedia(kind: String, media: RichMediaRef, caption: [RichText], duration: Int32? = nil) {
    let layout = item.mediaLayout ?? RichMessageBlockSizeCalculator.mediaLayout(
      for: media,
      caption: caption,
      width: bounds.width,
      style: style
    )
    addReusableMediaView(
      key: "media",
      signature: Self.mediaViewSignature(kind: kind, media: media, duration: duration, style: style),
      frame: isRTL ? mirrored(layout.mediaFrame) : layout.mediaFrame
    ) {
      RichMediaAppKitView(kind: kind, media: media, duration: duration, style: style, scrollState: scrollState)
    }

    if let captionFrame = layout.captionFrame {
      addTextView(
        RichTextAttributedStringBuilder.nsAttributedString(
          nodes: caption,
          font: style.baseFont,
          style: style,
          spoilerBaseID: "\(item.id).caption",
          state: state
        ),
        direction: resolvedDirection,
        frame: isRTL ? mirrored(captionFrame) : captionFrame,
        key: "caption"
      )
    }
  }

  private func addAudio(_ block: RichAudioBlock) {
    let layout = item.mediaLayout ?? RichMessageBlockSizeCalculator.audioLayout(
      for: block,
      width: bounds.width,
      style: style
    )
    addReusableMediaView(
      key: "audio",
      signature: Self.audioViewSignature(block: block, style: style),
      frame: isRTL ? mirrored(layout.mediaFrame) : layout.mediaFrame
    ) {
      RichAudioAppKitView(block: block, style: style)
    }

    if let captionFrame = layout.captionFrame {
      addTextView(
        RichTextAttributedStringBuilder.nsAttributedString(
          nodes: block.caption,
          font: style.baseFont,
          style: style,
          spoilerBaseID: "\(item.id).caption",
          state: state
        ),
        direction: resolvedDirection,
        frame: isRTL ? mirrored(captionFrame) : captionFrame,
        key: "caption"
      )
    }
  }

  private func addTable(_ block: RichTableBlock) {
    let tableLayout = item.tableLayout ?? RichMessageBlockSizeCalculator.tableLayout(
      for: block,
      width: bounds.width,
      style: style
    )
    let scrollFrame = CGRect(origin: .zero, size: tableLayout.viewportSize)
    let tableViews = reusableTableContainer(
      key: "table",
      scrollFrame: isRTL ? mirrored(scrollFrame) : scrollFrame,
      contentSize: tableLayout.contentSize,
      allowsHorizontalScroll: tableLayout.contentSize.width > tableLayout.viewportSize.width
    )

    for cell in tableLayout.cells {
      let cellFrame = isRTL ? mirrored(cell.frame, in: tableLayout.contentSize.width) : cell.frame
      let textFrame = isRTL ? mirrored(cell.textFrame, in: tableLayout.contentSize.width) : cell.textFrame
      let background = RichTableCellBackground(
        frame: cellFrame,
        color: block.striped && cell.row.isMultiple(of: 2) ? style.fill : .clear,
        border: block.bordered ? style.border : .clear,
        copyText: cell.cell.text.renderedPlainText
      )
      tableViews.content.addSubview(background)
      addTextView(
        RichTextAttributedStringBuilder.nsAttributedString(
          nodes: cell.cell.text,
          font: cell.cell.header ? .systemFont(ofSize: style.baseFont.pointSize, weight: .semibold) : style.baseFont,
          style: style,
          spoilerBaseID: "\(item.id).\(cell.id)",
          state: state
        ),
        direction: resolvedDirection,
        frame: textFrame,
        key: "table.\(cell.id)",
        parent: tableViews.content,
        alignment: textAlignment(for: cell.cell)
      )
    }

    if isRTL {
      tableViews.scroll.scrollToTrailingEdge(contentWidth: tableLayout.contentSize.width)
    }

    if let captionFrame = tableLayout.captionFrame {
      addTextView(
        RichTextAttributedStringBuilder.nsAttributedString(
          nodes: block.caption,
          font: style.baseFont,
          style: style,
          spoilerBaseID: "\(item.id).caption",
          state: state
        ),
        direction: resolvedDirection,
        frame: isRTL ? mirrored(captionFrame) : captionFrame,
        key: "caption"
      )
    }
  }

  private func addLabelCard(
    title: String,
    subtitle: String?,
    url: String? = nil,
    height: CGFloat? = nil,
    drawBackground: Bool = true,
    textLeadingInset: CGFloat = 10
  ) {
    let cardFrame = CGRect(x: 0, y: 0, width: bounds.width, height: height ?? bounds.height)
    reusableChromeView(key: "labelCard") {
      RichLabelCardView(frame: cardFrame)
    } configure: { card in
      card.configure(
        frame: cardFrame,
        title: title,
        subtitle: subtitle,
        url: RichURLCardOverlay.normalizedURL(from: url),
        style: style,
        isRTL: isRTL,
        drawBackground: drawBackground,
        textLeadingInset: textLeadingInset
      )
    }
  }

  private func addBlockCaption(_ caption: [RichText], y: CGFloat, width: CGFloat) {
    guard !caption.isEmpty, bounds.height > y else { return }

    let frame = CGRect(x: 0, y: y, width: max(1, width), height: max(1, bounds.height - y))
    addTextView(
      RichTextAttributedStringBuilder.nsAttributedString(
        nodes: caption,
        font: style.baseFont,
        style: style,
        spoilerBaseID: "\(item.id).caption",
        state: state
      ),
      direction: resolvedDirection,
      frame: isRTL ? mirrored(frame) : frame,
      key: "caption.\(Int((y * 100).rounded()))"
    )
  }

  private func mapFallbackURL(for block: RichMapBlock) -> String? {
    guard block.latitude.isFinite,
          block.longitude.isFinite,
          (-90...90).contains(block.latitude),
          (-180...180).contains(block.longitude)
    else { return nil }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "maps.apple.com"
    components.path = "/"

    let label = (block.hasTitle ? block.title : block.hasAddress ? block.address : "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var items = [
      URLQueryItem(name: "ll", value: "\(block.latitude),\(block.longitude)"),
    ]
    if !label.isEmpty {
      items.append(URLQueryItem(name: "q", value: label))
    }
    if block.zoom > 0 {
      items.append(URLQueryItem(name: "z", value: "\(min(max(block.zoom, 1), 20))"))
    }

    components.queryItems = items
    return components.url?.absoluteString
  }

  private func addEmbed(_ block: RichEmbedBlock) {
    let layout = item.embedLayout ?? RichMessageBlockSizeCalculator.embedLayout(
      for: block,
      width: bounds.width,
      style: style
    )

    addLabelCard(
      title: block.hasProvider ? block.provider : "Embed",
      subtitle: block.hasURL ? block.url : nil,
      url: block.hasURL ? block.url : nil,
      height: layout.cardFrame.height
    )

    if let mediaFrame = layout.mediaFrame, block.hasPoster {
      addReusableMediaView(
        key: "embed.poster",
        signature: Self.mediaViewSignature(kind: "Photo", media: block.poster, duration: nil, style: style),
        frame: isRTL ? mirrored(mediaFrame) : mediaFrame
      ) {
        RichMediaAppKitView(kind: "Photo", media: block.poster, duration: nil, style: style, scrollState: scrollState)
      }
    }

    if let captionFrame = layout.captionFrame {
      addTextView(
        RichTextAttributedStringBuilder.nsAttributedString(
          nodes: block.caption,
          font: style.baseFont,
          style: style,
          spoilerBaseID: "\(item.id).caption",
          state: state
        ),
        direction: resolvedDirection,
        frame: isRTL ? mirrored(captionFrame) : captionFrame,
        key: "caption"
      )
    }
  }

  private func addEmbedPost(_ block: RichEmbedPostBlock) {
    let layout = item.embedPostLayout ?? RichMessageBlockSizeCalculator.embedPostLayoutForAppKit(
      block,
      id: item.id,
      width: bounds.width,
      style: style,
      state: state
    ).layout

    reusableChromeView(key: "embedPost.background") {
      RichCardBackgroundView(frame: bounds, color: style.fill, cornerRadius: 6)
    } configure: { background in
      background.configure(frame: bounds, color: style.fill, cornerRadius: 6)
    }

    addLabelCard(
      title: block.author.isEmpty ? "Embedded post" : block.author,
      subtitle: nil,
      url: block.url,
      height: layout.headerFrame.height,
      drawBackground: false,
      textLeadingInset: block.hasAuthorPhoto ? 42 : 10
    )
    if let authorPhotoFrame = layout.authorPhotoFrame, block.hasAuthorPhoto {
      addReusableMediaView(
        key: "embedPost.authorPhoto",
        signature: Self.mediaViewSignature(kind: "Photo", media: block.authorPhoto, duration: nil, style: style),
        frame: isRTL ? mirrored(authorPhotoFrame) : authorPhotoFrame
      ) {
        RichMediaAppKitView(kind: "Photo", media: block.authorPhoto, duration: nil, style: style, scrollState: scrollState)
      }
    }

    if let child = item.children["post"] {
      let frame = layout.childFrame ?? CGRect(x: 10, y: 34, width: child.size.width, height: child.size.height)
      addNestedBlocks(
        layout: child,
        key: "post",
        frame: isRTL ? mirrored(frame) : frame,
        inheritedDirection: resolvedDirection
      )
    }

    if let captionFrame = layout.captionFrame {
      addTextView(
        RichTextAttributedStringBuilder.nsAttributedString(
          nodes: block.caption,
          font: style.baseFont,
          style: style,
          spoilerBaseID: "\(item.id).caption",
          state: state
        ),
        direction: resolvedDirection,
        frame: isRTL ? mirrored(captionFrame) : captionFrame,
        key: "caption"
      )
    }
  }

  private func addLinkPreview(_ block: RichLinkPreviewBlock) {
    let layout = item.linkPreviewLayout ?? RichMessageBlockSizeCalculator.linkPreviewLayout(
      for: block,
      width: bounds.width,
      style: style
    )

    reusableChromeView(key: "linkPreview.background") {
      RichCardBackgroundView(frame: bounds, color: style.fill, cornerRadius: 6)
    } configure: { background in
      background.configure(frame: bounds, color: style.fill, cornerRadius: 6)
    }

    if let url = RichURLCardOverlay.normalizedURL(from: block.url) {
      reusableChromeView(key: "linkPreview.overlay") {
        RichURLCardOverlay(url: url)
      } configure: { overlay in
        overlay.configure(url: url)
        overlay.frame = bounds
      }
    }

    reusableChromeView(key: "linkPreview.rule") {
      RichCardBackgroundView(
        frame: isRTL ? mirrored(layout.ruleFrame) : layout.ruleFrame,
        color: style.accent.withAlphaComponent(0.55),
        cornerRadius: 2
      )
    } configure: { rule in
      rule.configure(
        frame: isRTL ? mirrored(layout.ruleFrame) : layout.ruleFrame,
        color: style.accent.withAlphaComponent(0.55),
        cornerRadius: 2
      )
    }

    if let mediaFrame = layout.mediaFrame, block.hasMedia {
      addReusableMediaView(
        key: "linkPreview.media",
        signature: Self.mediaViewSignature(kind: "Photo", media: block.media, duration: nil, style: style),
        frame: isRTL ? mirrored(mediaFrame) : mediaFrame
      ) {
        RichMediaAppKitView(kind: "Photo", media: block.media, duration: nil, style: style, scrollState: scrollState)
      }
    }

    addTextView(
      RichMessageBlockSizeCalculator.linkPreviewAttributedString(for: block, style: style),
      direction: resolvedDirection,
      frame: isRTL ? mirrored(layout.textFrame) : layout.textFrame,
      key: "linkPreview.text"
    )
  }

  private func addCollage(_ block: RichCollageBlock) {
    let gap = CGFloat(6)
    let rowCount = (block.items.count + 1) / 2
    var rowHeights = Array(repeating: CGFloat(0), count: rowCount)
    var children: [(index: Int, layout: RichBlocksLayoutPlan)] = []

    for (index, _) in block.items.enumerated() {
      let childID = "\(item.id).collage.\(index)"
      guard let child = item.children[childID] else { continue }
      let row = index / 2
      rowHeights[row] = max(rowHeights[row], child.size.height)
      children.append((index: index, layout: child))
    }

    var rowOffsets = Array(repeating: CGFloat(0), count: rowCount)
    var y = CGFloat(0)
    for row in 0..<rowCount {
      rowOffsets[row] = y
      y += rowHeights[row]
      if row != rowCount - 1 {
        y += gap
      }
    }

    let cellWidth = max(1, (bounds.width - gap) / 2)
    for (index, child) in children {
      let column = index % 2
      let row = index / 2
      let x = CGFloat(column) * (cellWidth + gap)
      let frame = CGRect(x: x, y: rowOffsets[row], width: child.size.width, height: child.size.height)
      addNestedBlocks(
        layout: child,
        key: "collage.\(index)",
        frame: isRTL ? mirrored(frame) : frame,
        inheritedDirection: resolvedDirection
      )
    }

    addBlockCaption(block.caption, y: y + gap, width: bounds.width)
  }

  private func addBlocks(_ blocks: [RichBlock], key: String, inset: NSEdgeInsets) {
    guard !blocks.isEmpty else { return }
    let child = RichMessageBlockSizeCalculator.blocksLayoutForAppKit(
      blocks,
      path: "\(item.id).\(key)",
      width: max(1, bounds.width - inset.left - inset.right),
      style: style,
      state: state
    )
    let frame = CGRect(x: inset.left, y: inset.top, width: child.size.width, height: child.size.height)
    addNestedBlocks(
      layout: child,
      key: key,
      frame: isRTL ? mirrored(frame) : frame,
      inheritedDirection: resolvedDirection
    )
  }

  private func makeDisclosureButton(title: String, expanded: Bool, defaultExpanded: Bool) -> NSButton {
    let image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    let button = NSButton(title: title, image: image ?? NSImage(), target: self, action: #selector(toggleExpanded(_:)))
    button.imagePosition = .imageLeading
    button.isBordered = false
    button.alignment = isRTL ? .right : .left
    button.font = .systemFont(ofSize: max(11, style.baseFont.pointSize - 1), weight: .medium)
    button.contentTintColor = style.secondary
    button.tag = defaultExpanded ? 1 : 0
    return button
  }

  @objc private func toggleExpanded(_ sender: NSButton) {
    var next = state
    let defaultExpanded = sender.tag == 1
    next.overrides[item.id] = !state.isExpanded(id: item.id, defaultExpanded: defaultExpanded)
    stateDidChange?(next)
  }

  private func configureTextView(
    _ textView: RichSpoilerTextView,
    _ attributed: NSAttributedString,
    direction: RichDirection,
    frame: CGRect,
    alignment: NSTextAlignment? = nil
  ) {
    textView.frame = frame
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.font = style.baseFont
    textView.textColor = style.primary
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.lineFragmentPadding = 0
    textView.linkTextAttributes = [
      .foregroundColor: style.link,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
      .cursor: NSCursor.pointingHand,
    ]
    textView.richCopyTextProvider = copyTextProvider
    textView.richSelectionCoordinator = selectionCoordinator
    textView.richDirection = direction
    let selectedRangesBeforeUpdate = textView.selectedRanges
    textView.setMessageAttributedString(
      attributed,
      isRtl: direction == .directionRtl,
      layoutSize: frame.size,
      useTextKit2: true
    )
    textView.clampRichSelectionRanges(selectedRangesBeforeUpdate)
    if hasSpoilers(attributed) {
      textView.toolTip = "Click to reveal or hide spoiler"
    } else {
      textView.toolTip = nil
    }
    textView.onEntityClick = { [weak textView, state, stateDidChange] point, _ in
      if let spoilerID = textView?.spoilerID(at: point) {
        var next = state
        next.toggleSpoiler(id: spoilerID)
        stateDidChange?(next)
        return true
      }

      if let url = textView?.linkURL(at: point) {
        textView?.openLink(url)
        return true
      }

      return false
    }
    let range = NSRange(location: 0, length: textView.attributedString().length)
    let effectiveAlignment = alignment ?? .natural
    textView.alignment = effectiveAlignment
    textView.setAlignment(effectiveAlignment, range: range)
  }

  private func hasSpoilers(_ attributed: NSAttributedString) -> Bool {
    guard attributed.length > 0 else { return false }
    return attributed.attribute(.richSpoiler, at: 0, longestEffectiveRange: nil, in: NSRange(location: 0, length: attributed.length)) != nil ||
      (0..<attributed.length).contains { index in
        attributed.attribute(.richSpoiler, at: index, effectiveRange: nil) != nil
      }
  }

  private func textAlignment(for cell: RichTableCell) -> NSTextAlignment? {
    guard cell.hasAlign else { return nil }
    switch cell.align {
    case .horizontalAlignCenter:
      return .center
    case .horizontalAlignRight:
      return .right
    default:
      return .left
    }
  }

  private func headingFont(level: Int32) -> NSFont {
    let base = style.baseFont.pointSize
    let size: CGFloat = switch level {
    case 1: base + 7
    case 2: base + 5
    case 3: base + 3
    default: base + 1
    }
    return .systemFont(ofSize: size, weight: .semibold)
  }
}

private final class RichSpoilerTextView: MessageTextView {
  var richCopyTextProvider: RichCopyTextProvider?
  var richDirection: RichDirection = .directionUnspecified
  weak var richSelectionCoordinator: RichTextSelectionCoordinator?

  private var richSelectionMonitor: Any?

  var richTextLength: Int {
    textStorage?.length ?? attributedString().length
  }

  var isRichSelectionVisible: Bool {
    superview != nil && isRichSelectionVisibleContainer
  }

  #if DEBUG
  func debugSpoilerDiagnosticsForTestBook() -> RichRendererSpoilerDiagnostics {
    var diagnostics = RichRendererSpoilerDiagnostics()
    diagnostics.textLeafCount = 1

    let attributed = attributedString()
    let fullRange = NSRange(location: 0, length: attributed.length)
    guard fullRange.length > 0 else { return diagnostics }

    attributed.enumerateAttribute(.richSpoilerHidden, in: fullRange) { value, range, _ in
      guard let isHidden = value as? Bool,
            range.length > 0
      else { return }

      diagnostics.spoilerRangeCount += 1
      let spoilerIDValue = attributed.attribute(.richSpoilerID, at: range.location, effectiveRange: nil) as? String
      if let spoilerIDValue {
        diagnostics.spoilerIDs.insert(spoilerIDValue)
      }

      let hasLink = attributed.attribute(.link, at: range.location, effectiveRange: nil) != nil
      let point = debugHitTestPoint(for: range)
      if let point,
         let spoilerIDValue
      {
        if spoilerID(at: point) == spoilerIDValue {
          diagnostics.spoilerHitTargetCount += 1
        } else {
          diagnostics.spoilerHitTargetMissCount += 1
        }
      } else if spoilerIDValue != nil {
        diagnostics.spoilerHitTargetMissCount += 1
      }

      if let point,
         hasLink,
         linkURL(at: point) != nil
      {
        diagnostics.linkHitTargetCount += 1
        if isHidden, spoilerID(at: point) != nil {
          diagnostics.hiddenLinkRevealPriorityCount += 1
        }
      }

      if isHidden {
        diagnostics.hiddenRangeCount += 1
        if let spoilerIDValue {
          diagnostics.hiddenSpoilerIDs.insert(spoilerIDValue)
        }
        if hasLink {
          diagnostics.hiddenLinkRangeCount += 1
        }
      } else {
        diagnostics.revealedRangeCount += 1
        if let spoilerIDValue {
          diagnostics.revealedSpoilerIDs.insert(spoilerIDValue)
        }
        if hasLink {
          diagnostics.revealedLinkRangeCount += 1
        }
      }
    }

    return diagnostics
  }

  private func debugHitTestPoint(for range: NSRange) -> NSPoint? {
    guard let rect = renderedRects(for: range).first(where: { !$0.isEmpty }) else { return nil }
    return NSPoint(x: rect.midX, y: rect.midY)
  }

  private func debugFirstHiddenSpoilerClickTargetForTestBook(requireLink: Bool) -> (id: String, point: NSPoint)? {
    let attributed = attributedString()
    let fullRange = NSRange(location: 0, length: attributed.length)
    guard fullRange.length > 0 else { return nil }

    var click: (id: String, point: NSPoint)?
    attributed.enumerateAttribute(.richSpoilerHidden, in: fullRange) { value, range, stop in
      guard click == nil,
            (value as? Bool) == true,
            range.length > 0,
            let spoilerIDValue = attributed.attribute(.richSpoilerID, at: range.location, effectiveRange: nil) as? String
      else { return }

      let hasLink = attributed.attribute(.link, at: range.location, effectiveRange: nil) != nil
      guard !requireLink || hasLink else { return }
      guard let point = debugHitTestPoint(for: range),
            spoilerID(at: point) == spoilerIDValue
      else { return }

      click = (spoilerIDValue, point)
      stop.pointee = true
    }

    return click
  }

  func debugClickFirstHiddenSpoilerForTestBook(requireLink: Bool) -> String? {
    guard let click = debugFirstHiddenSpoilerClickTargetForTestBook(requireLink: requireLink) else { return nil }
    guard let event = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: convert(click.point, to: nil),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    ) else { return nil }

    return (onEntityClick?(click.point, event) == true) ? click.id : nil
  }

  func debugMouseDownFirstHiddenSpoilerForTestBook(requireLink: Bool) -> String? {
    guard let click = debugFirstHiddenSpoilerClickTargetForTestBook(requireLink: requireLink) else { return nil }
    guard let event = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: convert(click.point, to: nil),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    ) else { return nil }

    mouseDown(with: event)
    return click.id
  }
  #endif

  deinit {
    stopRichSelectionMonitoring()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stopRichSelectionMonitoring()
      richSelectionCoordinator?.cancelTracking()
    }
  }

  override func mouseDown(with event: NSEvent) {
    richSelectionCoordinator?.begin(from: self, event: event)
    startRichSelectionMonitoring(for: event)
    defer {
      stopRichSelectionMonitoring()
      richSelectionCoordinator?.finishTracking()
    }
    super.mouseDown(with: event)
  }

  override func copy(_ sender: Any?) {
    guard let payload = richCopyTextProvider?(), !payload.selected.isEmpty else {
      super.copy(sender)
      return
    }

    writeRichTextToPasteboard(payload.selected, attributed: payload.selectedAttributed)
  }

  override func selectAll(_ sender: Any?) {
    guard let richSelectionCoordinator else {
      super.selectAll(sender)
      return
    }

    richSelectionCoordinator.selectAll()
  }

  func richSelectionIndex(at point: NSPoint) -> Int? {
    guard richTextLength > 0 else { return nil }
    let index = characterIndexForInsertion(at: point)
    guard index != NSNotFound else { return nil }
    return min(max(0, index), richTextLength)
  }

  func clearRichSelection() {
    selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
  }

  func clampRichSelectionRanges(_ sourceRanges: [NSValue]? = nil) {
    let length = richTextLength
    var insertion = 0
    var ranges: [NSValue] = []

    for value in sourceRanges ?? selectedRanges {
      let range = value.rangeValue
      guard range.location != NSNotFound, range.location >= 0 else { continue }

      let start = min(range.location, length)
      if ranges.isEmpty {
        insertion = start
      }

      guard range.length > 0 else { continue }

      let rawEnd: Int
      if range.location > Int.max - range.length {
        rawEnd = Int.max
      } else {
        rawEnd = range.location + range.length
      }
      let end = min(max(start, rawEnd), length)
      guard end > start else { continue }

      ranges.append(NSValue(range: NSRange(location: start, length: end - start)))
    }

    if ranges.isEmpty {
      selectedRanges = [NSValue(range: NSRange(location: insertion, length: 0))]
    } else {
      selectedRanges = ranges
    }
  }

  private func startRichSelectionMonitoring(for event: NSEvent) {
    guard richSelectionCoordinator != nil else { return }
    guard event.type == .leftMouseDown, event.clickCount == 1 else { return }
    stopRichSelectionMonitoring()
    richSelectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] next in
      self?.richSelectionCoordinator?.track(event: next)
      return next
    }
  }

  private func stopRichSelectionMonitoring() {
    guard let richSelectionMonitor else { return }
    NSEvent.removeMonitor(richSelectionMonitor)
    self.richSelectionMonitor = nil
  }

  func linkURL(at point: NSPoint) -> URL? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    guard let characterIndex = characterIndex(at: point), characterIndex < textStorage.length else { return nil }

    var range = NSRange(location: 0, length: 0)
    let value = textStorage.attribute(.link, at: characterIndex, effectiveRange: &range)
    guard range.length > 0,
          renderedRange(range, contains: point)
    else { return nil }

    return Self.linkURL(from: value)
  }

  func openLink(_ url: URL) {
    guard Self.isAllowedLink(url) else { return }
    NSWorkspace.shared.open(url)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let location = convert(event.locationInWindow, from: nil)
    let inheritedMenu = super.menu(for: event)?.copy() as? NSMenu
    let menu = inheritedMenu ?? NSMenu()
    var didAddCustomItem = false

    if let url = linkURL(at: location) {
      let open = NSMenuItem(title: "Open Link", action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
      open.target = self
      open.representedObject = url
      open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open Link")

      let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLinkFromMenu(_:)), keyEquivalent: "")
      copy.target = self
      copy.representedObject = url
      copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Link")

      menu.insertItem(open, at: 0)
      menu.insertItem(copy, at: 1)
      if menu.items.count > 2 {
        menu.insertItem(.separator(), at: 2)
      }
      didAddCustomItem = true
    }

    if menu.items.isEmpty, !selectedPlainTextForRichCopy.isEmpty {
      let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
      copy.target = self
      copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
      menu.addItem(copy)
      didAddCustomItem = true
    }

    if let richCopyTextProvider {
      let payload = richCopyTextProvider()
      if !payload.selected.isEmpty || !payload.all.isEmpty {
        if didAddCustomItem || !menu.items.isEmpty {
          menu.addItem(.separator())
        }

        if !payload.selected.isEmpty {
          let copy = NSMenuItem(title: "Copy Selected Rich Text", action: #selector(copySelectedRichText), keyEquivalent: "")
          copy.target = self
          copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Selected Rich Text")
          menu.addItem(copy)
        }

        if !payload.all.isEmpty {
          let selectAll = NSMenuItem(title: "Select All Rich Text", action: #selector(selectAllRichTextFromMenu), keyEquivalent: "")
          selectAll.target = self
          selectAll.image = NSImage(systemSymbolName: "selection.pin.in.out", accessibilityDescription: "Select All Rich Text")
          menu.addItem(selectAll)

          let copy = NSMenuItem(title: "Copy Rich Message Text", action: #selector(copyRichMessageText), keyEquivalent: "")
          copy.target = self
          copy.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: "Copy Rich Message Text")
          menu.addItem(copy)
        }
      }
    }

    return menu.items.isEmpty ? nil : menu
  }

  func spoilerID(at point: NSPoint) -> String? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    guard let characterIndex = characterIndex(at: point), characterIndex < textStorage.length else { return nil }

    var range = NSRange(location: 0, length: 0)
    guard let spoilerID = textStorage.attribute(.richSpoilerID, at: characterIndex, effectiveRange: &range) as? String,
          range.length > 0,
          renderedRange(range, contains: point)
    else { return nil }

    return spoilerID
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

  private func renderedRange(_ range: NSRange, contains point: NSPoint) -> Bool {
    renderedRects(for: range).contains { rect in
      rect.insetBy(dx: -2, dy: -2).contains(point)
    }
  }

  private func renderedRects(for range: NSRange) -> [NSRect] {
    if let textLayoutManager, let textContentManager = textLayoutManager.textContentManager {
      guard let textRange = textRange(for: range, in: textContentManager) else { return [] }
      var rects: [NSRect] = []
      textLayoutManager.enumerateTextSegments(
        in: textRange,
        type: .standard,
        options: [.rangeNotRequired]
      ) { _, segmentRect, _, _ in
        var adjusted = segmentRect
        adjusted.origin.x += self.textContainerInset.width
        adjusted.origin.y += self.textContainerInset.height
        rects.append(adjusted)
        return true
      }
      return rects
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
      rects.append(adjusted)
    }
    return rects
  }

  private func textRange(for range: NSRange, in textContentManager: NSTextContentManager) -> NSTextRange? {
    let documentRange = textContentManager.documentRange
    guard let startLocation = textContentManager.location(documentRange.location, offsetBy: range.location),
          let endLocation = textContentManager.location(startLocation, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: startLocation, end: endLocation)
  }

  @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    openLink(url)
  }

  @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  #if DEBUG
  fileprivate func debugCopyFirstLinkForTestBook() -> RichContextCopyActionDebugSnapshot? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    var targetURL: URL?
    textStorage.enumerateAttribute(
      .link,
      in: NSRange(location: 0, length: textStorage.length),
      options: []
    ) { value, _, stop in
      guard let url = Self.linkURL(from: value),
            Self.isAllowedLink(url)
      else { return }
      targetURL = url
      stop.pointee = true
    }
    guard let targetURL else { return nil }

    let item = NSMenuItem(title: "Copy Link", action: #selector(copyLinkFromMenu(_:)), keyEquivalent: "")
    item.representedObject = targetURL
    copyLinkFromMenu(item)
    return RichContextCopyActionDebugSnapshot(
      menuTitle: "Copy Link",
      expectedText: targetURL.absoluteString,
      copiedText: NSPasteboard.general.string(forType: .string) ?? ""
    )
  }
  #endif

  @objc private func copySelectedRichText() {
    guard let payload = richCopyTextProvider?(), !payload.selected.isEmpty else { return }
    writeRichTextToPasteboard(payload.selected, attributed: payload.selectedAttributed)
  }

  @objc private func selectAllRichTextFromMenu() {
    richSelectionCoordinator?.selectAll()
  }

  @objc private func copyRichMessageText() {
    guard let text = richCopyTextProvider?().all, !text.isEmpty else { return }
    writeRichTextToPasteboard(text)
  }

  var selectedPlainTextForRichCopy: String {
    guard let textStorage, textStorage.length > 0 else { return "" }
    return selectedRanges
      .compactMap { value -> String? in
        let range = value.rangeValue
        guard range.length > 0,
              NSMaxRange(range) <= textStorage.length
        else { return nil }
        return textStorage.attributedSubstring(from: range).string
      }
      .joined()
  }

  var selectedAttributedTextForRichCopy: NSAttributedString? {
    guard let textStorage, textStorage.length > 0 else { return nil }
    let parts = selectedRanges.compactMap { value -> NSAttributedString? in
      let range = value.rangeValue
      guard range.length > 0,
            NSMaxRange(range) <= textStorage.length
      else { return nil }
      return textStorage.attributedSubstring(from: range)
    }
    return joinedAttributedText(parts)
  }

  private static func linkURL(from value: Any?) -> URL? {
    let url: URL?
    if let value = value as? URL {
      url = value
    } else if let value = value as? String {
      url = URL(string: value)
    } else {
      url = nil
    }

    guard let url, isAllowedLink(url) else { return nil }
    return url
  }

  private static func isAllowedLink(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "inline"
  }
}

private final class RichAudioAppKitView: NSView {
  private let block: RichAudioBlock
  private let style: RichMessageBlockStyle
  private let playButton = NSButton()
  private let waveformView = RichVoiceWaveformAppKitView()
  private let timeLabel = NSTextField(labelWithString: "")
  private var loadTask: Task<Void, Never>?
  private var playerCancellable: AnyCancellable?
  private var downloadCancellable: AnyCancellable?
  private var downloadProgress: DownloadProgress?
  private var message: InlineKit.Message?
  private var localURL: URL?
  private var sourceURL: URL?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  init(block: RichAudioBlock, style: RichMessageBlockStyle) {
    self.block = block
    self.style = style
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = style.fill.withAlphaComponent(0.72).cgColor
    layer?.cornerRadius = 10
    layer?.masksToBounds = true

    playButton.isBordered = false
    playButton.target = self
    playButton.action = #selector(handlePrimaryAction)
    addSubview(playButton)

    waveformView.foregroundColor = style.accent
    waveformView.backgroundColor = style.secondary.withAlphaComponent(0.28)
    waveformView.onSeek = { [weak self] progress in
      self?.seek(to: progress)
    }
    addSubview(waveformView)

    timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    timeLabel.textColor = style.secondary.withAlphaComponent(0.86)
    timeLabel.lineBreakMode = .byTruncatingTail
    addSubview(timeLabel)

    configure()
    Task { @MainActor [weak self] in
      self?.bindPlayer()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    loadTask?.cancel()
    playerCancellable?.cancel()
    downloadCancellable?.cancel()
  }

  override func layout() {
    super.layout()
    let buttonSize: CGFloat = min(28, max(22, bounds.height - 14))
    let buttonY = max(0, floor((bounds.height - buttonSize) / 2))
    playButton.frame = CGRect(x: 8, y: buttonY, width: buttonSize, height: buttonSize)

    let contentX = playButton.frame.maxX + 8
    let contentWidth = max(1, bounds.width - contentX - 8)
    waveformView.frame = CGRect(x: contentX, y: 8, width: contentWidth, height: 18)
    timeLabel.frame = CGRect(x: contentX, y: 27, width: contentWidth, height: 13)
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    let menu = NSMenu()

    if message != nil, localURL != nil {
      let save = NSMenuItem(title: "Save Audio", action: #selector(saveAudio), keyEquivalent: "")
      save.target = self
      save.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Audio")
      menu.addItem(save)

      let show = NSMenuItem(title: "Show Audio in Finder", action: #selector(showAudio), keyEquivalent: "")
      show.target = self
      show.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show Audio in Finder")
      menu.addItem(show)

      let copy = NSMenuItem(title: "Copy Audio File", action: #selector(copyAudioFile), keyEquivalent: "")
      copy.target = self
      copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Audio File")
      menu.addItem(copy)
    }

    if sourceURL != nil {
      if !menu.items.isEmpty {
        menu.addItem(.separator())
      }

      let open = NSMenuItem(title: "Open Source URL", action: #selector(openSourceURL), keyEquivalent: "")
      open.target = self
      open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open Source URL")
      menu.addItem(open)

      let copy = NSMenuItem(title: "Copy Audio URL", action: #selector(copySourceURL), keyEquivalent: "")
      copy.target = self
      copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Audio URL")
      menu.addItem(copy)
    }

    guard !menu.items.isEmpty else { return nil }
    return menu
  }

  private func configure() {
    if case let .publicURL(value)? = block.media.media {
      sourceURL = URL(string: value)
    }

    updateControls(state: nil)

    guard case let .voiceID(voiceID)? = block.media.media else { return }
    bindDownloadProgress(voiceID: voiceID)
    loadTask = Task { [weak self] in
      let hydrated = await Self.localVoiceMessage(voiceID: voiceID)
      await MainActor.run {
        guard let self else { return }
        if let hydrated {
          self.message = hydrated
          self.localURL = hydrated.voiceLocalURL
          self.waveformView.waveform = hydrated.voiceContent?.waveform ?? Data()
        } else if let voice = self.richVoiceContent(localURL: nil) {
          self.message = self.syntheticRichVoiceMessage(voice)
          self.localURL = nil
          self.sourceURL = URL(string: voice.cdnURL)
          self.waveformView.waveform = voice.waveform
        }
        self.updateControls(state: SharedAudioPlayer.shared.state)
      }
    }
  }

  @MainActor
  private func bindPlayer() {
    playerCancellable = SharedAudioPlayer.shared.$state.sink { [weak self] state in
      self?.updateControls(state: state)
    }
  }

  @MainActor
  private func bindDownloadProgress(voiceID: Int64) {
    downloadCancellable = FileDownloader.shared.voiceProgressPublisher(voiceId: voiceID).sink { [weak self] progress in
      self?.downloadProgress = progress
      self?.updateControls(state: SharedAudioPlayer.shared.state)
    }
  }

  private func updateControls(state: SharedAudioPlayerState?) {
    let active = playerState(state)
    let isPlaying = active?.isPlaying == true
    let hasLocalVoice = message != nil && localURL != nil
    let canDownloadVoice = message != nil && localURL == nil && sourceURL != nil && voiceID != nil
    let isDownloading = canDownloadVoice && downloadProgress?.isComplete == false && downloadProgress?.error == nil &&
      FileDownloader.shared.isVoiceDownloadActive(voiceId: voiceID ?? 0)
    let symbolName: String
    let enabled: Bool
    let tooltip: String

    if hasLocalVoice {
      symbolName = isPlaying ? "pause.fill" : "play.fill"
      enabled = true
      tooltip = isPlaying ? "Pause audio" : "Play audio"
    } else if isDownloading {
      symbolName = "arrow.down.circle"
      enabled = false
      tooltip = "Downloading audio"
    } else if canDownloadVoice {
      symbolName = "arrow.down.circle"
      enabled = true
      tooltip = "Download audio"
    } else if sourceURL != nil {
      symbolName = "arrow.up.forward"
      enabled = true
      tooltip = "Open audio URL"
    } else {
      symbolName = "arrow.down"
      enabled = false
      tooltip = "Audio is not available locally"
    }

    playButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
    playButton.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
    playButton.contentTintColor = hasLocalVoice || sourceURL != nil ? style.accent : style.secondary.withAlphaComponent(0.52)
    playButton.toolTip = tooltip
    playButton.isEnabled = enabled

    waveformView.isSeekingEnabled = hasLocalVoice
    if let active, active.duration > 0 {
      waveformView.progress = min(max(active.currentTime / active.duration, 0), 1)
      timeLabel.stringValue = Self.format(duration: active.currentTime)
      return
    }

    waveformView.progress = 0
    if hasLocalVoice {
      timeLabel.stringValue = Self.format(duration: TimeInterval(message?.voiceContent?.duration ?? block.duration))
    } else if isDownloading, let downloadProgress {
      let percent = Int((downloadProgress.progress * 100).rounded())
      timeLabel.stringValue = percent > 0 ? "Downloading \(percent)%" : "Downloading..."
    } else if sourceURL != nil {
      timeLabel.stringValue = sourceURL?.host ?? "Open audio URL"
    } else if block.hasTitle || block.hasPerformer {
      timeLabel.stringValue = [block.title, block.performer].filter { !$0.isEmpty }.joined(separator: " - ")
    } else if block.duration > 0 {
      timeLabel.stringValue = Self.format(duration: TimeInterval(block.duration))
    } else if let voiceID {
      timeLabel.stringValue = "Voice #\(voiceID)"
    } else {
      timeLabel.stringValue = "Audio"
    }
  }

  private var voiceID: Int64? {
    guard case let .voiceID(value)? = block.media.media else { return nil }
    return value
  }

  private func playerState(_ state: SharedAudioPlayerState?) -> SharedAudioPlayerState? {
    guard let state, let item = state.item, let message, let voice = message.voiceContent else { return nil }
    guard item.kind == .voice,
          item.chatId == message.chatId,
          item.messageId == message.messageId,
          item.mediaId == voice.voiceID
    else { return nil }
    return state
  }

  @objc private func handlePrimaryAction() {
    if message != nil, localURL == nil, sourceURL != nil, richVoiceContent(localURL: nil) != nil {
      downloadAndPlayRichVoice()
      return
    }

    if let sourceURL, message == nil {
      NSWorkspace.shared.open(sourceURL)
      return
    }

    guard let message, let localURL else { return }
    Task { @MainActor in
      do {
        try SharedAudioPlayer.shared.toggleVoicePlayback(for: message, fileURLOverride: localURL)
      } catch {
        ToastCenter.shared.showError("Audio isn't available")
      }
    }
  }

  private func seek(to progress: Double) {
    guard let message, let localURL else { return }
    Task { @MainActor in
      do {
        if playerState(SharedAudioPlayer.shared.state) == nil {
          try SharedAudioPlayer.shared.prepareVoice(for: message, fileURLOverride: localURL)
        }
        SharedAudioPlayer.shared.seekVoice(to: progress, for: message)
      } catch {
        ToastCenter.shared.showError("Audio isn't available")
      }
    }
  }

  @objc private func saveAudio() {
    guard let message else { return }
    Task { @MainActor in
      VoiceMessageAudioSaver.save(message: message, window: window)
    }
  }

  private func downloadAndPlayRichVoice() {
    guard let voice = richVoiceContent(localURL: nil) else { return }
    guard !FileDownloader.shared.isVoiceDownloadActive(voiceId: voice.voiceID) else { return }
    FileDownloader.shared.downloadRichVoice(voice: voice) { [weak self] result in
      guard let self else { return }
      switch result {
      case let .success(url):
        self.localURL = url
        let playableVoice = self.richVoiceContent(localURL: url) ?? voice
        self.message = self.syntheticRichVoiceMessage(playableVoice)
        self.waveformView.waveform = playableVoice.waveform
        self.updateControls(state: SharedAudioPlayer.shared.state)
        self.playDownloadedRichVoice()
      case .failure:
        self.updateControls(state: SharedAudioPlayer.shared.state)
        ToastCenter.shared.showError("Audio isn't available")
      }
    }
  }

  private func playDownloadedRichVoice() {
    guard let message, let localURL else { return }
    Task { @MainActor in
      do {
        try SharedAudioPlayer.shared.playVoice(for: message, fileURLOverride: localURL)
      } catch {
        ToastCenter.shared.showError("Audio isn't available")
      }
    }
  }

  @objc private func showAudio() {
    guard let localURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([localURL])
  }

  @objc private func copyAudioFile() {
    guard let localURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([localURL as NSURL])
  }

  @objc private func openSourceURL() {
    guard let sourceURL else { return }
    NSWorkspace.shared.open(sourceURL)
  }

  @objc private func copySourceURL() {
    guard let sourceURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(sourceURL.absoluteString, forType: .string)
  }

  #if DEBUG
  fileprivate func debugCopySourceForTestBook() -> RichContextCopyActionDebugSnapshot? {
    guard let sourceURL else { return nil }
    copySourceURL()
    return RichContextCopyActionDebugSnapshot(
      menuTitle: "Copy Audio URL",
      expectedText: sourceURL.absoluteString,
      copiedText: NSPasteboard.general.string(forType: .string) ?? ""
    )
  }
  #endif

  private static func localVoiceMessage(voiceID: Int64) async -> InlineKit.Message? {
    #if DEBUG
    if richTestBookSkipsPersistentMediaHydration() {
      return nil
    }
    #endif

    return try? await AppDatabase.shared.dbWriter.read { db in
      let cursor = try InlineKit.Message
        .filter(sql: "contentPayload IS NOT NULL")
        .fetchCursor(db)

      while let message = try cursor.next() {
        guard message.voiceContent?.voiceID == voiceID,
              let localURL = message.voiceLocalURL,
              FileManager.default.fileExists(atPath: localURL.path)
        else { continue }
        return message
      }

      return nil
    }
  }

  private func richVoiceContent(localURL: URL?) -> Client_MessageVoiceContent? {
    guard case let .voiceID(voiceID)? = block.media.media, voiceID > 0 else { return nil }
    guard block.media.hasCdnURL,
          !block.media.cdnURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    let mimeType = block.media.hasMimeType && !block.media.mimeType.isEmpty ? block.media.mimeType : "audio/ogg"
    return Client_MessageVoiceContent.with {
      $0.voiceID = voiceID
      $0.duration = max(block.duration, 0)
      $0.waveform = Data()
      $0.mimeType = mimeType
      $0.cdnURL = block.media.cdnURL
      $0.localRelativePath = localURL.flatMap(Self.voiceLocalRelativePath) ?? ""
    }
  }

  private func syntheticRichVoiceMessage(_ voice: Client_MessageVoiceContent) -> InlineKit.Message {
    InlineKit.Message(
      messageId: -max(1, abs(voice.voiceID)),
      fromId: 0,
      date: .distantPast,
      text: nil,
      peerUserId: 0,
      peerThreadId: nil,
      chatId: 0,
      out: false,
      contentPayload: Client_MessageContentPayload.with {
        $0.voice = voice
      }
    )
  }

  private static func voiceLocalRelativePath(for url: URL) -> String? {
    let cache = FileHelpers.getLocalCacheDirectory(for: .voices).standardizedFileURL
    let file = url.standardizedFileURL
    guard file.path.hasPrefix(cache.path) else { return nil }
    return file.lastPathComponent
  }

  private static func format(duration: TimeInterval) -> String {
    guard duration.isFinite, duration > 0 else { return "0:00" }
    let totalSeconds = Int(duration.rounded())
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return "\(minutes):\(String(format: "%02d", seconds))"
  }
}

private final class RichVoiceWaveformAppKitView: NSView {
  var waveform = Data() {
    didSet { needsDisplay = true }
  }

  var progress: Double = 0 {
    didSet { needsDisplay = true }
  }

  var foregroundColor = NSColor.controlAccentColor {
    didSet { needsDisplay = true }
  }

  var backgroundColor = NSColor.secondaryLabelColor {
    didSet { needsDisplay = true }
  }

  var isSeekingEnabled = false {
    didSet { needsDisplay = true }
  }

  var onSeek: ((Double) -> Void)?

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard bounds.width > 0, bounds.height > 0 else { return }

    let barWidth: CGFloat = 1.5
    let barSpacing: CGFloat = 2
    let stride = barWidth + barSpacing
    let barCount = max(8, min(48, Int(bounds.width / stride)))
    let samples = normalizedSamples(count: barCount)
    let progressIndex = Int((Double(barCount) * min(max(progress, 0), 1)).rounded(.down))

    for index in 0..<barCount {
      let sample = samples[index]
      let height = max(2, ceil(bounds.height * CGFloat(sample)))
      let x = CGFloat(index) * stride
      let y = max(0, bounds.height - height)
      let rect = CGRect(x: x, y: y, width: barWidth, height: height)
      (index < progressIndex && isSeekingEnabled ? foregroundColor : backgroundColor).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 0.75, yRadius: 0.75).fill()
    }
  }

  override func mouseDown(with event: NSEvent) {
    seek(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    seek(with: event)
  }

  private func seek(with event: NSEvent) {
    guard isSeekingEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    let value = Double(min(max(point.x / max(1, bounds.width), 0), 1))
    onSeek?(value)
  }

  private func normalizedSamples(count: Int) -> [Double] {
    guard count > 0 else { return [] }
    let bytes = Array(waveform)
    guard !bytes.isEmpty else {
      return (0..<count).map { index in
        0.22 + (Double((index * 37) % 9) / 12)
      }
    }

    return (0..<count).map { index in
      let start = index * bytes.count / count
      let end = max(start + 1, (index + 1) * bytes.count / count)
      let slice = bytes[start..<min(end, bytes.count)]
      let peak = slice.map { Double($0) / 255 }.max() ?? 0.2
      return max(0.14, min(1, peak))
    }
  }
}

#if DEBUG
private func richTestBookSkipsPersistentMediaHydration() -> Bool {
  CommandLine.arguments.contains("--rich-text-testbook-only")
}
#endif

private enum RichMediaPrimaryClickAction {
  case none
  case quickLook
}

private extension RichMediaPrimaryClickAction {
  var opensSourceURL: Bool {
    switch self {
    case .none, .quickLook:
      return false
    }
  }
}

private final class RichMediaAppKitView: NSView {
  private let imageLayer = CALayer()
  private let label = NSTextField(labelWithString: "")
  private let symbol = NSImageView()
  private let style: RichMessageBlockStyle
  private let duration: Int32?
  private let isImageMedia: Bool
  private var loadTask: Task<Void, Never>?
  private var nativePhotoView: NewPhotoView?
  private var nativeVideoView: NewVideoView?
  private var nativeDocumentView: DocumentView?
  private var currentImage: NSImage?
  private var currentURL: URL?
  private var sourceURL: URL?
  private var tempPreviewImageURL: URL?
  private var labelValue = ""
  private var scrollState: MessageListScrollState = .idle

  override var isFlipped: Bool { true }

  init(
    kind: String,
    media: RichMediaRef,
    duration: Int32?,
    style: RichMessageBlockStyle,
    scrollState: MessageListScrollState
  ) {
    self.style = style
    self.duration = duration
    self.scrollState = scrollState
    isImageMedia = Self.isImageKind(kind)
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = style.fill.withAlphaComponent(0.65).cgColor
    layer?.cornerRadius = 7
    layer?.borderWidth = 0
    layer?.masksToBounds = true

    imageLayer.contentsGravity = .resizeAspect
    imageLayer.masksToBounds = true
    layer?.addSublayer(imageLayer)

    symbol.image = NSImage(systemSymbolName: symbolName(for: kind), accessibilityDescription: kind)
    symbol.contentTintColor = style.secondary.withAlphaComponent(0.8)
    symbol.symbolConfiguration = .init(pointSize: 22, weight: .regular)
    addSubview(symbol)

    label.font = .systemFont(ofSize: max(11, style.baseFont.pointSize - 1), weight: .medium)
    label.textColor = style.secondary
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)

    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    addGestureRecognizer(click)

    configure(kind: kind, media: media)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    loadTask?.cancel()
    clearTemporaryPreviewImage()
  }

  override func layout() {
    super.layout()
    nativePhotoView?.frame = bounds
    nativeVideoView?.frame = bounds
    nativeDocumentView?.frame = bounds
    imageLayer.frame = bounds
    if bounds.height <= 60 {
      symbol.frame = CGRect(
        x: 8,
        y: max(0, (bounds.height - 24) / 2),
        width: 24,
        height: 24
      )
      label.alignment = .left
      label.frame = CGRect(
        x: 40,
        y: max(0, (bounds.height - 16) / 2),
        width: max(1, bounds.width - 48),
        height: 16
      )
      return
    }
    label.alignment = .center
    symbol.frame = CGRect(
      x: max(0, (bounds.width - 28) / 2),
      y: max(8, (bounds.height - 46) / 2),
      width: 28,
      height: 28
    )
    label.frame = CGRect(
      x: 10,
      y: min(bounds.height - 22, symbol.frame.maxY + 5),
      width: max(1, bounds.width - 20),
      height: 16
    )
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    contextMenu()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isImageMedia, nativePhotoView == nil else {
      return super.hitTest(point)
    }
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
    return self
  }

  func setScrollState(_ state: MessageListScrollState) {
    scrollState = state
    nativePhotoView?.setIsScrolling(state.isScrolling)
    nativeVideoView?.setIsScrolling(state.isScrolling)
  }

  private func contextMenu() -> NSMenu? {
    let menu = NSMenu()

    if canQuickLookImage {
      let preview = NSMenuItem(title: "Quick Look Image", action: #selector(openQuickLook), keyEquivalent: "")
      preview.target = self
      preview.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Quick Look Image")
      menu.addItem(preview)
    }

    if isImageMedia, currentImage != nil {
      let copyImage = NSMenuItem(title: "Copy Image", action: #selector(copyImage), keyEquivalent: "")
      copyImage.target = self
      copyImage.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Image")
      menu.addItem(copyImage)

      let saveImage = NSMenuItem(title: "Save Image", action: #selector(saveImage), keyEquivalent: "")
      saveImage.target = self
      saveImage.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Image")
      menu.addItem(saveImage)
    }

    if !isImageMedia, currentURL != nil {
      let open = NSMenuItem(title: openSourceTitle, action: #selector(openSource), keyEquivalent: "")
      open.target = self
      open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: openSourceTitle)
      menu.addItem(open)
    }

    if !isImageMedia, sourceURL != nil || currentURL != nil {
      let copyURL = NSMenuItem(title: copySourceTitle, action: #selector(copySource), keyEquivalent: "")
      copyURL.target = self
      copyURL.image = NSImage(systemSymbolName: "link", accessibilityDescription: copySourceTitle)
      menu.addItem(copyURL)
    }

    guard !menu.items.isEmpty else { return nil }
    return menu
  }

  private func configure(kind: String, media: RichMediaRef) {
    loadTask?.cancel()
    loadTask = nil
    labelValue = labelText(kind: kind, media: media)
    label.stringValue = labelValue

    switch media.media {
    case let .publicURL(value):
      guard let url = publicMediaURL(value) else {
        setLoadFailure(kind: kind)
        return
      }
      loadImage(from: url, kind: kind)
    case let .photoID(photoID):
      resolvePhoto(photoID: photoID, fallbackURL: fallbackURL(from: media))
    case let .videoID(videoID):
      resolveVideo(videoID: videoID, fallbackMedia: media)
    case let .documentID(documentID):
      resolveDocument(documentID: documentID, fallbackMedia: media)
    default:
      setLoadFailure(kind: kind)
    }
  }

  private func publicMediaURL(_ value: String) -> URL? {
    RichMediaURLPolicy.safeRemoteMediaURL(from: value)
  }

  private func fallbackURL(from media: RichMediaRef) -> URL? {
    guard media.hasCdnURL else { return nil }
    return RichMediaURLPolicy.safeRemoteMediaURL(from: media.cdnURL)
  }

  private func loadImage(from url: URL, kind: String) {
    currentURL = url
    sourceURL = url

    let request = ImageRequest(url: url)
    if let cached = ImagePipeline.shared.cache.cachedImage(for: request) {
      setImage(cached.image)
      return
    }

    loadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let image = try await ImagePipeline.shared.image(for: request)
        guard !Task.isCancelled else { return }
        self.setImage(image)
      } catch {
        guard !Task.isCancelled else { return }
        self.setLoadFailure(kind: kind)
      }
    }
  }

  private func loadPhoto(_ photoInfo: PhotoInfo, fallbackURL: URL?) {
    guard let size = photoInfo.bestPhotoSize() else {
      if let fallbackURL {
        loadImage(from: fallbackURL, kind: "Photo")
      } else {
        setLoadFailure(kind: "Photo")
      }
      return
    }

    if let localPath = size.localPath {
      let url = FileCache.getUrl(for: .photos, localPath: localPath)
      if FileManager.default.fileExists(atPath: url.path) {
        currentURL = url
        sourceURL = nil
        useNativePhotoView(photoInfo: photoInfo, localURL: url)
        if let image = NSImage(contentsOf: url) {
          currentImage = image
        }
        nativePhotoView?.menu = contextMenu()
        return
      }
    }

    guard let url = size.cdnUrl.flatMap(URL.init(string:)) ?? fallbackURL else {
      setLoadFailure(kind: "Photo")
      return
    }
    loadImage(from: url, kind: "Photo")
    Task {
      await FileCache.shared.download(photo: photoInfo)
    }
  }

  private func resolvePhoto(photoID: Int64, fallbackURL: URL?) {
    #if DEBUG
    if richTestBookSkipsPersistentMediaHydration() {
      if let fallbackURL {
        loadImage(from: fallbackURL, kind: "Photo")
      } else {
        setLoadFailure(kind: "Photo")
      }
      return
    }
    #endif

    loadTask = Task { [weak self] in
      let photoInfo = await Self.photoInfo(photoID: photoID)
      await MainActor.run {
        guard let self else { return }
        guard let photoInfo else {
          if let fallbackURL {
            self.loadImage(from: fallbackURL, kind: "Photo")
          } else {
            self.setLoadFailure(kind: "Photo")
          }
          return
        }
        self.loadPhoto(photoInfo, fallbackURL: fallbackURL)
      }
    }
  }

  private func resolveDocument(documentID: Int64, fallbackMedia: RichMediaRef) {
    #if DEBUG
    if richTestBookSkipsPersistentMediaHydration() {
      setLoadFailure(kind: "Document")
      return
    }
    #endif

    loadTask = Task { [weak self] in
      let documentInfo = await Self.ensureDocumentInfo(documentID: documentID, media: fallbackMedia)
      await MainActor.run {
        guard let self else { return }
        guard let documentInfo else {
          self.setLoadFailure(kind: "Document")
          return
        }
        self.useNativeDocumentView(documentInfo: documentInfo)
      }
    }
  }

  private func resolveVideo(videoID: Int64, fallbackMedia: RichMediaRef) {
    #if DEBUG
    if richTestBookSkipsPersistentMediaHydration() {
      setLoadFailure(kind: "Video")
      return
    }
    #endif

    let blockDuration = duration
    loadTask = Task { [weak self] in
      let videoInfo = await Self.ensureVideoInfo(videoID: videoID, media: fallbackMedia, duration: blockDuration)
      await MainActor.run {
        guard let self else { return }
        guard let videoInfo else {
          self.setLoadFailure(kind: "Video")
          return
        }
        guard self.canUseNativeVideoView(videoInfo: videoInfo) else {
          self.setLoadFailure(kind: "Video")
          return
        }
        self.useNativeVideoView(videoInfo: videoInfo)
      }
    }
  }

  private func useNativePhotoView(photoInfo: PhotoInfo, localURL _: URL) {
    clearNativeMediaSubviews()

    var fullMessage = syntheticFullMessage(photoInfo: photoInfo)
    fullMessage.photoInfo = photoInfo

    let photoView = NewPhotoView(fullMessage, scrollState: scrollState, roundsAllCorners: true)
    photoView.cornerRadiusReduction = 3
    applyNativeMediaFrame(photoView)
    addSubview(photoView, positioned: .above, relativeTo: nil)
    nativePhotoView = photoView

    imageLayer.isHidden = true
    label.isHidden = true
    symbol.isHidden = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  private func useNativeDocumentView(documentInfo: DocumentInfo) {
    clearNativeMediaSubviews()

    let documentView = DocumentView(documentInfo: documentInfo, fullMessage: nil, white: false)
    applyNativeMediaFrame(documentView)
    addSubview(documentView, positioned: .above, relativeTo: nil)
    nativeDocumentView = documentView

    imageLayer.isHidden = true
    label.isHidden = true
    symbol.isHidden = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  private func useNativeVideoView(videoInfo: VideoInfo) {
    clearNativeMediaSubviews()

    var fullMessage = syntheticFullMessage(videoInfo: videoInfo)
    fullMessage.videoInfo = videoInfo

    let videoView = NewVideoView(fullMessage, scrollState: scrollState, roundsAllCorners: true)
    applyNativeMediaFrame(videoView)
    videoView.menu = nativeVideoMenu(videoView: videoView)
    addSubview(videoView, positioned: .above, relativeTo: nil)
    nativeVideoView = videoView

    if let localPath = videoInfo.video.localPath {
      currentURL = FileCache.getUrl(for: .videos, localPath: localPath)
      sourceURL = nil
    }

    imageLayer.isHidden = true
    label.isHidden = true
    symbol.isHidden = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  private func applyNativeMediaFrame(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = true
    view.autoresizingMask = []
    view.frame = bounds
  }

  private func canUseNativeVideoView(videoInfo: VideoInfo) -> Bool {
    if let localPath = videoInfo.video.localPath {
      let url = FileCache.getUrl(for: .videos, localPath: localPath)
      if FileManager.default.fileExists(atPath: url.path) {
        guard let thumbSize = videoInfo.thumbnail?.bestPhotoSize() else { return true }
        guard let thumbLocalPath = thumbSize.localPath else { return false }
        let thumbURL = FileCache.getUrl(for: .photos, localPath: thumbLocalPath)
        return FileManager.default.fileExists(atPath: thumbURL.path)
      }
    }

    return videoInfo.video.cdnUrl?.isEmpty == false
  }

  private func nativeVideoMenu(videoView: NewVideoView) -> NSMenu {
    let menu = NSMenu()
    let save = NSMenuItem(title: "Save Video", action: #selector(NewVideoView.saveVideo), keyEquivalent: "")
    save.target = videoView
    save.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Video")
    menu.addItem(save)
    return menu
  }

  #if DEBUG
  fileprivate func debugRichMediaScrollSnapshotForTestBook() -> RichMediaScrollDebugSnapshot {
    let nativeCount = (nativePhotoView == nil ? 0 : 1) + (nativeVideoView == nil ? 0 : 1)
    return RichMediaScrollDebugSnapshot(
      mediaViewCount: 1,
      scrollingMediaViewCount: scrollState.isScrolling ? 1 : 0,
      idleMediaViewCount: scrollState.isScrolling ? 0 : 1,
      nativeMediaViewCount: nativeCount,
      scrollingNativeMediaViewCount: scrollState.isScrolling ? nativeCount : 0,
      idleNativeMediaViewCount: scrollState.isScrolling ? 0 : nativeCount,
      mediaViewFrames: [frame]
    )
  }

  fileprivate func debugRichMediaClickSnapshotForTestBook() -> RichMediaClickDebugSnapshot {
    let action = primaryClickAction
    let preparedPreviewURL = canQuickLookImage ? preparePreviewImageURL() : nil
    let didPrepareQuickLook = Self.previewFileExists(preparedPreviewURL)
    let delegatesClickToNativePhoto = nativePhotoView != nil && NewPhotoView.debugPrimaryClickSnapshotForTestBook().isPreviewOnly
    var dispatchedQuickLook = false
    let dispatchedAction = performPrimaryClick {
      dispatchedQuickLook = Self.previewFileExists(preparedPreviewURL ?? preparePreviewImageURL())
    }
    let menuTitles = Set((contextMenu()?.items ?? []).compactMap { item -> String? in
      guard !item.isSeparatorItem, !item.title.isEmpty else { return nil }
      return item.title
    })
    return RichMediaClickDebugSnapshot(
      mediaViewCount: 1,
      imageMediaViewCount: isImageMedia ? 1 : 0,
      previewableImageCount: canQuickLookImage ? 1 : 0,
      primaryPreviewOnlyCount: action == .quickLook ? 1 : 0,
      primarySourceOpenCount: action.opensSourceURL ? 1 : 0,
      quickLookPreparedImageCount: didPrepareQuickLook ? 1 : 0,
      quickLookPrepareFailureCount: canQuickLookImage && !didPrepareQuickLook ? 1 : 0,
      quickLookPrepareFailureDetails: canQuickLookImage && !didPrepareQuickLook ? ["preview item URL missing"] : [],
      primaryClickDispatchPreviewCount: dispatchedQuickLook || delegatesClickToNativePhoto ? 1 : 0,
      primaryClickDispatchSourceOpenCount: dispatchedAction.opensSourceURL ? 1 : 0,
      primaryClickClosesPreviewPanelCount: imageClickClosesVisiblePreviewPanel ? 1 : 0,
      nonImagePrimaryPreviewCount: !isImageMedia && action == .quickLook ? 1 : 0,
      imageSourceContextMenuActionCount: isImageMedia && (
        menuTitles.contains("Open Source URL") ||
          menuTitles.contains("Open Image")
      ) ? 1 : 0,
      imageSourceCopyActionCount: isImageMedia && menuTitles.contains("Copy Image URL") ? 1 : 0,
      nonImageSourceContextMenuActionCount: !isImageMedia && menuTitles.contains("Open Source URL") ? 1 : 0,
      nonImageSourceCopyActionCount: !isImageMedia && menuTitles.contains("Copy Media URL") ? 1 : 0,
      sourceContextMenuActionCount: menuTitles.contains("Open Source URL") ? 1 : 0
    )
  }

  fileprivate func debugCopySourceForTestBook() -> RichContextCopyActionDebugSnapshot? {
    guard !isImageMedia, let url = sourceURL ?? currentURL else { return nil }
    copySource()
    return RichContextCopyActionDebugSnapshot(
      menuTitle: copySourceTitle,
      expectedText: url.absoluteString,
      copiedText: NSPasteboard.general.string(forType: .string) ?? ""
    )
  }
  #endif

  private func syntheticFullMessage(photoInfo: PhotoInfo) -> FullMessage {
    let message = Message(
      messageId: -max(1, abs(photoInfo.photo.photoId)),
      fromId: 0,
      date: .distantPast,
      text: nil,
      peerUserId: 0,
      peerThreadId: nil,
      chatId: 0,
      out: false,
      photoId: photoInfo.photo.photoId
    )
    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  private func syntheticFullMessage(videoInfo: VideoInfo) -> FullMessage {
    let message = Message(
      messageId: -max(1, abs(videoInfo.video.videoId)),
      fromId: 0,
      date: .distantPast,
      text: nil,
      peerUserId: 0,
      peerThreadId: nil,
      chatId: 0,
      out: false,
      videoId: videoInfo.video.videoId
    )
    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  private static func photoInfo(photoID: Int64) async -> PhotoInfo? {
    try? await AppDatabase.shared.dbWriter.read { db in
      guard let photo = try InlineKit.Photo
        .filter(Column("photoId") == photoID)
        .fetchOne(db),
        let localPhotoID = photo.id
      else { return nil }

      let sizes = try InlineKit.PhotoSize
        .filter(Column("photoId") == localPhotoID)
        .fetchAll(db)

      return PhotoInfo(photo: photo, sizes: sizes)
    }
  }

  private static func documentInfo(documentID: Int64) async -> DocumentInfo? {
    try? await AppDatabase.shared.dbWriter.read { db in
      guard let document = try InlineKit.Document
        .filter(Column("documentId") == documentID)
        .fetchOne(db)
      else { return nil }

      let thumbnail: PhotoInfo?
      if let thumbnailPhotoID = document.thumbnailPhotoId,
         let photo = try InlineKit.Photo
           .filter(Column("id") == thumbnailPhotoID)
           .fetchOne(db),
         let localPhotoID = photo.id
      {
        let sizes = try InlineKit.PhotoSize
          .filter(Column("photoId") == localPhotoID)
          .fetchAll(db)
        thumbnail = PhotoInfo(photo: photo, sizes: sizes)
      } else {
        thumbnail = nil
      }

      return DocumentInfo(document: document, photoInfo: thumbnail)
    }
  }

  private static func ensureDocumentInfo(documentID: Int64, media: RichMediaRef) async -> DocumentInfo? {
    let existing = await documentInfo(documentID: documentID)
    let cdnURL = hydrationCdnURL(from: media)

    if let existing, hasUsableDocumentInfo(existing) || cdnURL == nil {
      return existing
    }

    guard let cdnURL else { return existing }
    let fileName = mediaString(media.fileName, enabled: media.hasFileName)
      ?? mediaString(media.alt, enabled: true)
      ?? existing?.document.fileName
      ?? "Document"
    let mimeType = mediaString(media.mimeType, enabled: media.hasMimeType)
      ?? existing?.document.mimeType
      ?? "application/octet-stream"
    let now = Int64(Date().timeIntervalSince1970)

    let saved = try? await AppDatabase.shared.dbWriter.write { db in
      var proto = InlineProtocol.Document()
      proto.id = documentID
      proto.date = now
      proto.fileName = fileName
      proto.mimeType = mimeType
      proto.size = 0
      proto.cdnURL = cdnURL.absoluteString

      let document = try InlineKit.Document.updateFromProtocol(
        db,
        protoDocument: proto,
        thumbnailPhotoId: nil
      )
      return DocumentInfo(document: document)
    }
    return await documentInfo(documentID: documentID) ?? saved
  }

  private static func videoInfo(videoID: Int64) async -> VideoInfo? {
    try? await AppDatabase.shared.dbWriter.read { db in
      guard let video = try InlineKit.Video
        .filter(Column("videoId") == videoID)
        .fetchOne(db)
      else { return nil }

      let thumbnail: PhotoInfo?
      if let thumbnailPhotoID = video.thumbnailPhotoId,
         let photo = try InlineKit.Photo
           .filter(Column("id") == thumbnailPhotoID)
           .fetchOne(db),
         let localPhotoID = photo.id
      {
        let sizes = try InlineKit.PhotoSize
          .filter(Column("photoId") == localPhotoID)
          .fetchAll(db)
        thumbnail = PhotoInfo(photo: photo, sizes: sizes)
      } else {
        thumbnail = nil
      }

      return VideoInfo(video: video, photoInfo: thumbnail)
    }
  }

  private static func ensureVideoInfo(videoID: Int64, media: RichMediaRef, duration: Int32?) async -> VideoInfo? {
    let existing = await videoInfo(videoID: videoID)
    let cdnURL = hydrationCdnURL(from: media)

    if let existing, hasUsableVideoInfo(existing) || cdnURL == nil {
      return existing
    }

    guard let cdnURL else { return existing }
    let now = Int64(Date().timeIntervalSince1970)

    let saved = try? await AppDatabase.shared.dbWriter.write { db in
      var proto = InlineProtocol.Video()
      proto.id = videoID
      proto.date = now
      proto.w = media.hasWidth ? max(0, media.width) : Int32(existing?.video.width ?? 0)
      proto.h = media.hasHeight ? max(0, media.height) : Int32(existing?.video.height ?? 0)
      proto.duration = duration.map { max(0, $0) } ?? Int32(existing?.video.duration ?? 0)
      proto.size = 0
      proto.cdnURL = cdnURL.absoluteString

      let video = try InlineKit.Video.updateFromProtocol(
        db,
        protoVideo: proto,
        thumbnailPhotoId: nil
      )
      return VideoInfo(video: video)
    }
    return await videoInfo(videoID: videoID) ?? saved
  }

  private static func hydrationCdnURL(from media: RichMediaRef) -> URL? {
    guard media.hasCdnURL else { return nil }
    return RichMediaURLPolicy.safeRemoteMediaURL(from: media.cdnURL)
  }

  private static func hasUsableDocumentInfo(_ info: DocumentInfo) -> Bool {
    if info.document.cdnUrl?.isEmpty == false { return true }
    guard let localPath = info.document.localPath else { return false }
    let url = FileCache.getUrl(for: .documents, localPath: localPath)
    return FileManager.default.fileExists(atPath: url.path)
  }

  private static func hasUsableVideoInfo(_ info: VideoInfo) -> Bool {
    if info.video.cdnUrl?.isEmpty == false { return true }
    guard let localPath = info.video.localPath else { return false }
    let url = FileCache.getUrl(for: .videos, localPath: localPath)
    return FileManager.default.fileExists(atPath: url.path)
  }

  private static func mediaString(_ value: String, enabled: Bool) -> String? {
    guard enabled else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func setImage(_ image: NSImage) {
    clearTemporaryPreviewImage()
    clearNativeMediaSubviews()
    currentImage = image
    imageLayer.contents = image
    imageLayer.isHidden = false
    label.isHidden = true
    symbol.isHidden = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  private func setLoadFailure(kind: String) {
    clearTemporaryPreviewImage()
    currentImage = nil
    imageLayer.contents = nil
    imageLayer.isHidden = false
    clearNativeMediaSubviews()

    symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Unable to load \(kind)")
    symbol.contentTintColor = style.secondary.withAlphaComponent(0.86)
    symbol.isHidden = false
    label.stringValue = "Unable to load \(kind.lowercased())"
    label.isHidden = false
    layer?.backgroundColor = style.fill.withAlphaComponent(0.65).cgColor
    needsLayout = true
  }

  private func clearNativeMediaSubviews() {
    nativePhotoView?.removeFromSuperview()
    nativePhotoView = nil
    nativeVideoView?.removeFromSuperview()
    nativeVideoView = nil
    nativeDocumentView?.removeFromSuperview()
    nativeDocumentView = nil
  }

  @objc private func copyImage() {
    guard let currentImage else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([currentImage])
  }

  @objc private func openSource() {
    guard !isImageMedia, let currentURL else { return }
    NSWorkspace.shared.open(currentURL)
  }

  @objc private func openQuickLook() {
    guard preparePreviewImageURL() != nil, let panel = QLPreviewPanel.shared() else {
      return
    }
    window?.makeFirstResponder(self)
    panel.updateController()
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
  }

  @objc private func handleClick(_: NSClickGestureRecognizer) {
    performPrimaryClick {
      openQuickLook()
    }
  }

  @discardableResult
  private func performPrimaryClick(openQuickLook: () -> Void) -> RichMediaPrimaryClickAction {
    guard nativePhotoView == nil else { return .none }
    let action = primaryClickAction
    switch action {
    case .quickLook:
      openQuickLook()
    case .none:
      break
    }
    return action
  }

  @objc private func saveImage() {
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.png, .jpeg]
    savePanel.nameFieldStringValue = saveFileName
    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    savePanel.canCreateDirectories = true
    let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let destinationURL = savePanel.url else { return }
      self?.writeImage(to: destinationURL)
    }
    if let window {
      savePanel.beginSheetModal(for: window, completionHandler: handler)
    } else {
      savePanel.begin(completionHandler: handler)
    }
  }

  @objc private func copySource() {
    guard !isImageMedia, let url = sourceURL ?? currentURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  private func labelText(kind: String, media: RichMediaRef) -> String {
    if !media.alt.isEmpty {
      return media.alt
    }
    return switch media.media {
    case let .photoID(id): "Photo #\(id)"
    case let .videoID(id): "Video #\(id)"
    case let .documentID(id): "Document #\(id)"
    case let .voiceID(id): "Voice #\(id)"
    case .publicURL: "Loading \(kind.lowercased())"
    case nil: kind
    }
  }

  private func writeImage(to destinationURL: URL) {
    do {
      let fileManager = FileManager.default
      if let currentURL, currentURL.isFileURL {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: currentURL, to: destinationURL)
        return
      }

      guard let data = pngData else { return }
      try data.write(to: destinationURL, options: .atomic)
    } catch {
      assertionFailure("Failed to save rich image: \(error)")
    }
  }

  private var pngData: Data? {
    guard let tiff = currentImage?.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }

  private var canQuickLookImage: Bool {
    guard isImageMedia else { return false }
    return currentURL?.isFileURL == true || currentImage != nil
  }

  private var primaryClickAction: RichMediaPrimaryClickAction {
    canQuickLookImage ? .quickLook : .none
  }

  private var imageClickClosesVisiblePreviewPanel: Bool {
    false
  }

  private var previewImageURL: URL? {
    guard isImageMedia else { return nil }
    if currentURL?.isFileURL == true {
      return currentURL
    }
    guard let tempPreviewImageURL,
          FileManager.default.fileExists(atPath: tempPreviewImageURL.path)
    else {
      return nil
    }
    return tempPreviewImageURL
  }

  private func preparePreviewImageURL() -> URL? {
    guard isImageMedia else { return nil }
    if currentURL?.isFileURL == true {
      return currentURL
    }
    if let previewImageURL {
      return previewImageURL
    }
    guard let data = pngData else { return nil }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-rich-image-\(UUID().uuidString)")
      .appendingPathExtension("png")
    do {
      try data.write(to: url, options: .atomic)
      tempPreviewImageURL = url
      return url
    } catch {
      return nil
    }
  }

  private func clearTemporaryPreviewImage() {
    guard let tempPreviewImageURL else { return }
    try? FileManager.default.removeItem(at: tempPreviewImageURL)
    self.tempPreviewImageURL = nil
  }

  private var saveFileName: String {
    if let currentURL, currentURL.isFileURL {
      return currentURL.lastPathComponent.isEmpty ? "image.png" : currentURL.lastPathComponent
    }
    if let sourceURL, !sourceURL.lastPathComponent.isEmpty {
      return sourceURL.lastPathComponent
    }
    return "image.png"
  }

  private var openSourceTitle: String {
    return currentURL?.isFileURL == true ? "Open Media File" : "Open Source URL"
  }

  private var copySourceTitle: String {
    "Copy Media URL"
  }

  private func symbolName(for kind: String) -> String {
    switch kind.lowercased() {
    case "video":
      return "play.rectangle"
    case "document":
      return "doc"
    default:
      return "photo"
    }
  }

  private static func isImageKind(_ kind: String) -> Bool {
    switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "photo", "image":
      return true
    default:
      return false
    }
  }

  private static func previewFileExists(_ url: URL?) -> Bool {
    guard let url, url.isFileURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }
}

extension RichMediaAppKitView {
  override var acceptsFirstResponder: Bool { true }

  override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
    previewImageURL != nil
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }
}

extension RichMediaAppKitView: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
    previewImageURL != nil ? 1 : 0
  }

  func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> QLPreviewItem! {
    self
  }
}

extension RichMediaAppKitView: QLPreviewPanelDelegate {
  func previewPanel(_: QLPreviewPanel!, sourceFrameOnScreenFor _: QLPreviewItem!) -> NSRect {
    window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
  }

  func previewPanel(_: QLPreviewPanel!, transitionImageFor _: QLPreviewItem!, contentRect _: UnsafeMutablePointer<NSRect>!) -> Any! {
    currentImage
  }
}

extension RichMediaAppKitView: QLPreviewItem {
  var previewItemURL: URL! {
    previewImageURL
  }

  var previewItemTitle: String! {
    labelValue.isEmpty ? "Image Preview" : labelValue
  }
}

private final class RichHorizontalScrollView: NSScrollView {
  var allowsHorizontalScroll = true
  #if DEBUG
  var debugHandledWheelCount = 0
  var debugForwardedWheelCount = 0
  #endif

  func scrollToTrailingEdge(contentWidth: CGFloat) {
    let x = max(0, contentWidth - contentView.bounds.width)
    guard x > 0 else { return }
    contentView.scroll(to: NSPoint(x: x, y: 0))
    reflectScrolledClipView(contentView)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
      return nil
    }
    let clipPoint = convert(point, to: contentView)
    if contentView.bounds.contains(clipPoint),
       let documentView
    {
      let documentPoint = convert(point, to: documentView)
      if documentView.bounds.contains(documentPoint),
         let hit = documentView.hitTest(documentPoint)
      {
        return hit
      }
    }
    return super.hitTest(point)
  }

  override func scrollWheel(with event: NSEvent) {
    guard RichTableWheelRouting.shouldHandleInTable(
      allowsHorizontalScroll: allowsHorizontalScroll,
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      modifierFlags: event.modifierFlags
    ) else {
      forwardWheelToParent(with: event)
      return
    }
    #if DEBUG
    debugHandledWheelCount += 1
    #endif
    super.scrollWheel(with: event)
  }

  private func forwardWheelToParent(with event: NSEvent) {
    #if DEBUG
    debugForwardedWheelCount += 1
    #endif
    var view = superview
    while let current = view {
      if let scrollView = current as? NSScrollView {
        scrollView.scrollWheel(with: event)
        return
      }
      view = current.superview
    }

    nextResponder?.scrollWheel(with: event)
  }
}

#if DEBUG
private final class RichTableWheelParentProbeScrollView: NSScrollView {
  var debugScrollWheelCount = 0

  override func scrollWheel(with event: NSEvent) {
    debugScrollWheelCount += 1
  }
}
#endif

enum RichTableWheelRouting {
  static func shouldHandleInTable(
    allowsHorizontalScroll: Bool,
    deltaX: CGFloat,
    deltaY: CGFloat,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    let horizontal = abs(deltaX)
    let vertical = abs(deltaY)
    let shiftHorizontal = modifierFlags.contains(.shift) && vertical > 0
    return allowsHorizontalScroll && (horizontal > 0 || shiftHorizontal) && (horizontal > vertical || shiftHorizontal)
  }

  #if DEBUG
  static func debugBehaviorDiagnosticsForTestBook() -> RichTableWheelBehaviorDiagnostics {
    var diagnostics = RichTableWheelBehaviorDiagnostics()

    guard let vertical = wheelEvent(deltaX: 0, deltaY: 8, modifierFlags: []),
          let disabledHorizontal = wheelEvent(deltaX: 8, deltaY: 0, modifierFlags: []),
          let horizontal = wheelEvent(deltaX: 8, deltaY: 0, modifierFlags: []),
          let shift = wheelEvent(deltaX: 0, deltaY: 8, modifierFlags: .shift)
    else {
      diagnostics.eventCreationFailed = true
      return diagnostics
    }

    diagnostics.verticalForwarded = probe(event: vertical, allowsHorizontalScroll: true).forwardedToParent
    diagnostics.disabledHorizontalForwarded = probe(event: disabledHorizontal, allowsHorizontalScroll: false).forwardedToParent
    diagnostics.horizontalHandled = probe(event: horizontal, allowsHorizontalScroll: true).handledByTable
    diagnostics.shiftWheelHandled = probe(event: shift, allowsHorizontalScroll: true).handledByTable
    return diagnostics
  }

  private static func probe(event: NSEvent, allowsHorizontalScroll: Bool) -> (handledByTable: Bool, forwardedToParent: Bool) {
    let parent = RichTableWheelParentProbeScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    parent.documentView = container

    let table = RichHorizontalScrollView(frame: CGRect(x: 0, y: 0, width: 180, height: 80))
    table.allowsHorizontalScroll = allowsHorizontalScroll
    table.hasHorizontalScroller = true
    table.hasVerticalScroller = false
    table.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 80))
    container.addSubview(table)
    table.layoutSubtreeIfNeeded()

    table.scrollWheel(with: event)
    return (
      handledByTable: table.debugHandledWheelCount > 0 && parent.debugScrollWheelCount == 0,
      forwardedToParent: table.debugForwardedWheelCount > 0 && parent.debugScrollWheelCount > 0
    )
  }

  private static func wheelEvent(deltaX: CGFloat, deltaY: CGFloat, modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
    guard let event = CGEvent(
      scrollWheelEvent2Source: nil,
      units: .pixel,
      wheelCount: 2,
      wheel1: Int32(deltaY),
      wheel2: Int32(deltaX),
      wheel3: 0
    )
    else { return nil }

    var flags: CGEventFlags = []
    if modifierFlags.contains(.shift) {
      flags.insert(.maskShift)
    }
    event.flags = flags
    event.location = CGPoint(x: 40, y: 40)
    return NSEvent(cgEvent: event)
  }
  #endif
}

private final class RichFlippedView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
    for subview in subviews.reversed() {
      let subviewPoint = convert(point, to: subview)
      guard subview.bounds.contains(subviewPoint),
            let hit = subview.hitTest(subviewPoint)
      else { continue }
      return hit
    }
    return nil
  }
}

private final class RichCardBackgroundView: NSView {
  override var isFlipped: Bool { true }

  init(frame: CGRect, color: NSColor, cornerRadius: CGFloat) {
    super.init(frame: frame)
    wantsLayer = true
    configure(frame: frame, color: color, cornerRadius: cornerRadius)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(frame: CGRect, color: NSColor, cornerRadius: CGFloat) {
    self.frame = frame
    layer?.backgroundColor = color.cgColor
    layer?.cornerRadius = cornerRadius
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }
}

private final class RichCodeCopyButton: NSButton {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, isEnabled, bounds.contains(point) else {
      return nil
    }
    return self
  }
}

private final class RichLabelCardView: NSView {
  private let background = RichCardBackgroundView(frame: .zero, color: .clear, cornerRadius: 6)
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private var overlay: RichURLCardOverlay?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(background)

    titleLabel.lineBreakMode = .byTruncatingTail
    addSubview(titleLabel)

    subtitleLabel.lineBreakMode = .byTruncatingTail
    addSubview(subtitleLabel)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    frame: CGRect,
    title: String,
    subtitle: String?,
    url: URL?,
    style: RichMessageBlockStyle,
    isRTL: Bool,
    drawBackground: Bool,
    textLeadingInset: CGFloat
  ) {
    self.frame = frame

    background.configure(frame: bounds, color: style.fill, cornerRadius: 6)
    background.isHidden = !drawBackground
    let leadingInset = max(10, textLeadingInset)
    let textX = isRTL ? 10 : leadingInset
    let textTrailingInset = isRTL ? leadingInset : 10
    let textWidth = max(1, bounds.width - textX - textTrailingInset)

    titleLabel.stringValue = title
    titleLabel.font = .systemFont(ofSize: style.baseFont.pointSize, weight: .medium)
    titleLabel.textColor = style.primary
    titleLabel.alignment = isRTL ? .right : .left
    titleLabel.frame = CGRect(x: textX, y: 9, width: textWidth, height: 18)

    let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    subtitleLabel.isHidden = subtitle.isEmpty
    subtitleLabel.stringValue = subtitle
    subtitleLabel.font = .systemFont(ofSize: max(11, style.baseFont.pointSize - 2))
    subtitleLabel.textColor = style.secondary
    subtitleLabel.alignment = isRTL ? .right : .left
    subtitleLabel.frame = CGRect(x: textX, y: 28, width: textWidth, height: 16)

    if let url {
      let overlay = overlay ?? RichURLCardOverlay(url: url)
      overlay.configure(url: url)
      overlay.frame = bounds
      overlay.isHidden = false
      if overlay.superview !== self {
        addSubview(overlay)
      }
      self.overlay = overlay
    } else {
      overlay?.isHidden = true
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let overlay, !overlay.isHidden else { return nil }
    let overlayPoint = convert(point, to: overlay)
    return overlay.hitTest(overlayPoint)
  }
}

private final class RichURLCardOverlay: NSView {
  private var url: URL

  override var isFlipped: Bool { true }

  init(url: URL) {
    self.url = url
    super.init(frame: .zero)
    toolTip = url.absoluteString
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(url: URL) {
    self.url = url
    toolTip = url.absoluteString
    discardCursorRects()
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseUp(with event: NSEvent) {
    guard event.buttonNumber == 0 else {
      super.mouseUp(with: event)
      return
    }
    openURL()
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let open = NSMenuItem(title: "Open Link", action: #selector(openURL), keyEquivalent: "")
    open.target = self
    open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open Link")
    menu.addItem(open)

    let copy = NSMenuItem(title: "Copy Link", action: #selector(copyURL), keyEquivalent: "")
    copy.target = self
    copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Link")
    menu.addItem(copy)
    return menu
  }

  @objc private func openURL() {
    NSWorkspace.shared.open(url)
  }

  @objc private func copyURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  #if DEBUG
  fileprivate func debugCopyURLForTestBook() -> RichContextCopyActionDebugSnapshot {
    copyURL()
    return RichContextCopyActionDebugSnapshot(
      menuTitle: "Copy Link",
      expectedText: url.absoluteString,
      copiedText: NSPasteboard.general.string(forType: .string) ?? ""
    )
  }
  #endif

  static func normalizedURL(from value: String?) -> URL? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto", "inline"].contains(scheme)
    else { return nil }
    return url
  }
}

private final class RichTableCellBackground: NSView {
  private let color: NSColor
  private let border: NSColor
  private let copyText: String

  override var isFlipped: Bool { true }

  init(frame frameRect: NSRect, color: NSColor, border: NSColor, copyText: String) {
    self.color = color
    self.border = border
    self.copyText = copyText.trimmingCharacters(in: .whitespacesAndNewlines)
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = color.cgColor
    layer?.borderColor = border.cgColor
    layer?.borderWidth = border == .clear ? 0 : 0.5
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    guard !copyText.isEmpty else { return nil }

    let menu = NSMenu()
    let copy = NSMenuItem(title: "Copy Cell", action: #selector(copyCellText), keyEquivalent: "")
    copy.target = self
    copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Cell")
    menu.addItem(copy)
    return menu
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !copyText.isEmpty, !isHidden, alphaValue > 0.01, bounds.contains(point) else {
      return nil
    }
    return self
  }

  @objc private func copyCellText() {
    guard !copyText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(copyText, forType: .string)
  }

  #if DEBUG
  fileprivate func debugBackgroundHitPointForTestBook() -> NSPoint {
    NSPoint(
      x: bounds.minX + min(2, max(0, bounds.width - 1)),
      y: bounds.minY + min(2, max(0, bounds.height - 1))
    )
  }

  fileprivate func debugCopyCellForTestBook(
    sourceHitTested: Bool = false,
    sourceHitView: String = ""
  ) -> RichContextCopyActionDebugSnapshot? {
    guard !copyText.isEmpty else { return nil }
    copyCellText()
    return RichContextCopyActionDebugSnapshot(
      menuTitle: "Copy Cell",
      expectedText: copyText,
      copiedText: NSPasteboard.general.string(forType: .string) ?? "",
      source: "tableCellBackground",
      sourceHitTested: sourceHitTested,
      sourceHitView: sourceHitView
    )
  }
  #endif
}
