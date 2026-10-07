import AppKit
import InlineKit
import RealtimeV2

enum ServiceMessageRowLayout {
  struct Plan: Equatable {
    var rowSize: NSSize
    var containerFrame: NSRect
    var textFrame: NSRect
    var textSize: NSSize
    var singleLine: Bool
  }

  static let preferredHeight: CGFloat = 34
  static let horizontalInset: CGFloat = 10
  static let verticalInset: CGFloat = 5
  static let maxWidthFraction: CGFloat = 0.9
  static let cornerRadius: CGFloat = 11
  static let fontSize: CGFloat = 12
  static let font = NSFont.systemFont(ofSize: fontSize)

  private static let emptyFallback = " "
  private static let measurer = TextMeasurer(
    font: font,
    lineBreakMode: .byCharWrapping,
    extraHeight: 1
  )

  static func segments(for message: FullMessage) -> [MessageServiceDisplaySegment] {
    message.serviceDisplaySegments ?? [
      MessageServiceDisplaySegment(text: message.message.serviceFallbackText
        ?? message.message.text
        ?? message.message.stringRepresentationPlain),
    ]
  }

  static func displayText(for message: FullMessage) -> String {
    segments(for: message).map(\.text).joined()
  }

  static func plan(for message: FullMessage, rowSize: NSSize) -> Plan {
    let textSize = textSize(for: message, rowWidth: rowSize.width)
    return plan(textSize: textSize, rowSize: rowSize, leading: message.message.isGridTranscript)
  }

  static func calculateSize(
    for message: FullMessage,
    tableWidth width: CGFloat
  ) -> (size: NSSize, textSize: NSSize, layout: MessageSizeCalculator.LayoutPlans) {
    let textSize = textSize(for: message, rowWidth: width)
    let rowSize = NSSize(width: width, height: rowHeight(textHeight: textSize.height))
    let plan = plan(textSize: textSize, rowSize: rowSize, leading: message.message.isGridTranscript)
    let wrapperPlan = MessageSizeCalculator.LayoutPlan(size: plan.rowSize, spacing: .zero)
    let zeroPlan = MessageSizeCalculator.LayoutPlan(size: .zero, spacing: .zero)
    let layout = MessageSizeCalculator.LayoutPlans(
      wrapper: wrapperPlan,
      name: nil,
      avatar: nil,
      bubble: zeroPlan,
      text: nil,
      richBlockContent: nil,
      photo: nil,
      video: nil,
      document: nil,
      attachmentItems: [],
      attachments: nil,
      forwardHeader: nil,
      reply: nil,
      replyThreadSummary: nil,
      reactions: nil,
      actionsRows: nil,
      reactionItems: [:],
      reactionsOutsideBubble: false,
      reactionsOutsideBubbleTopInset: 0,
      timeInContentFlow: false,
      hasAcknowledgement: false,
      time: nil,
      singleLine: plan.singleLine,
      emojiMessage: false,
      fontSize: fontSize,
      hasBubbleColor: false
    )

    return (plan.rowSize, plan.textSize, layout)
  }

  private static func plan(textSize: NSSize, rowSize: NSSize, leading: Bool) -> Plan {
    let textWidth = min(maxTextWidth(rowWidth: rowSize.width), max(1, textSize.width))
    let textHeight = max(1, textSize.height)
    let containerWidth = textWidth + horizontalInset * 2
    let containerHeight = textHeight + verticalInset * 2
    let containerFrame = NSRect(
      x: leading ? floor((rowSize.width - maxContainerWidth(rowWidth: rowSize.width)) / 2) :
        floor((rowSize.width - containerWidth) / 2),
      y: floor((rowSize.height - containerHeight) / 2),
      width: ceil(containerWidth),
      height: ceil(containerHeight)
    )
    let textFrame = NSRect(
      x: horizontalInset,
      y: verticalInset,
      width: floor(textWidth),
      height: ceil(textHeight)
    )

    return Plan(
      rowSize: rowSize,
      containerFrame: containerFrame,
      textFrame: textFrame,
      textSize: NSSize(width: textWidth, height: textHeight),
      singleLine: rowSize.height <= preferredHeight
    )
  }

  private static func textSize(for message: FullMessage, rowWidth: CGFloat) -> NSSize {
    let text = displayText(for: message)
    let value = text.isEmpty ? emptyFallback : text
    let maxWidth = maxTextWidth(rowWidth: rowWidth)
    let natural = measurer.measure(value, width: 10_000)
    let width = min(max(1, maxWidth), max(1, natural.width))
    let wrapped = measurer.measure(value, width: width)
    return NSSize(width: width, height: max(1, wrapped.height))
  }

  private static func maxTextWidth(rowWidth: CGFloat) -> CGFloat {
    max(1, maxContainerWidth(rowWidth: rowWidth) - horizontalInset * 2)
  }

  private static func maxContainerWidth(rowWidth: CGFloat) -> CGFloat {
    max(1, floor(rowWidth * maxWidthFraction))
  }

  private static func rowHeight(textHeight: CGFloat) -> CGFloat {
    max(preferredHeight, ceil(textHeight) + verticalInset * 2)
  }
}

final class ServiceMessageViewAppKit: NSView, MessageTableRenderableView, NSMenuItemValidation {
  private let containerView = NSView()
  private lazy var textView = ServiceMessageTextView { [weak self] link in
    self?.open(link)
  }

  private var fullMessage: FullMessage
  private var dependencies: AppDependencies?

  init(fullMessage: FullMessage, dependencies: AppDependencies?) {
    self.fullMessage = fullMessage
    self.dependencies = dependencies
    super.init(frame: .zero)
    setupView()
    updateText()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateText()
    updateAppearance()
  }

  override func layout() {
    super.layout()
    layoutContent()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    let textPoint = containerView.convert(localPoint, from: self)
    if let hit = textView.hitTest(textPoint) {
      return hit
    }
    if containerView.frame.contains(localPoint) {
      return self
    }
    return nil
  }

  func setDependencies(_ dependencies: AppDependencies) {
    self.dependencies = dependencies
  }

  func updateTextAndSize(fullMessage: FullMessage, props _: MessageViewProps, animate _: Bool) {
    self.fullMessage = fullMessage
    updateText()
  }

  func updateSize(props _: MessageViewProps) {
    needsLayout = true
  }

  func reflectBoundsChange(fraction _: CGFloat) {}

  func setScrollState(_: MessageListScrollState) {}

  func reset() {}

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = .clear

    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = ServiceMessageRowLayout.cornerRadius
    containerView.layer?.masksToBounds = true
    addSubview(containerView)

    containerView.addSubview(textView)
    let menu = makeContextMenu()
    self.menu = menu
    textView.menu = menu

    updateAppearance()
  }

  private func updateText() {
    textView.setSegments(
      ServiceMessageRowLayout.segments(for: fullMessage),
      leading: fullMessage.message.isGridTranscript
    )
    needsLayout = true
    needsDisplay = true
  }

  private func layoutContent() {
    guard bounds.width > 1, bounds.height > 1 else { return }

    let plan = ServiceMessageRowLayout.plan(for: fullMessage, rowSize: bounds.size)
    containerView.frame = plan.containerFrame
    textView.frame = plan.textFrame
  }

  private func updateAppearance() {
    containerView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor
  }

  private func open(_ link: MessageServiceDisplaySegment.Link) {
    switch link {
      case let .user(userId):
        dependencies?.requestOpenChat(peer: .user(id: userId))
      case let .thread(chatId):
        dependencies?.requestOpenChat(peer: .thread(id: chatId))
    }
  }

  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    if fullMessage.message.isGridTranscript {
      let copyItem = NSMenuItem(title: "Copy", action: #selector(copyTranscript), keyEquivalent: "")
      copyItem.target = self
      menu.addItem(copyItem)
    }
    let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteMessage), keyEquivalent: "delete")
    deleteItem.target = self
    deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
    menu.addItem(deleteItem)
    return menu
  }

  @objc private func copyTranscript() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(fullMessage.message.text ?? "", forType: .string)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(deleteMessage) else { return true }
    // This row has no Space role projection. Keep server authority for signed-in
    // readers rather than fetching membership while constructing a menu.
    return dependencies?.auth.getCurrentUserId() != nil
  }

  @objc private func deleteMessage() {
    let message = fullMessage.message
    Task(priority: .userInitiated) { @MainActor in
      do {
        try await Api.realtime.send(DeleteMessageTransaction(
          messageIds: [message.messageId],
          peerId: message.peerId,
          chatId: message.chatId,
          deferLocalDeletion: message.isGridTranscript
        ))
      } catch {
        let notice: String
        if let failure = error as? TransactionError,
           case let .rpcError(rpc) = failure,
           rpc.errorCode == .spaceAdminRequired
        {
          notice = message.isGridTranscript
            ? "Only the person who started transcription or a space admin can delete this message."
            : "Only the author or a space admin can delete this message."
        } else {
          notice = "Could not delete message. Please try again."
        }
        ToastCenter.shared.showError(notice)
      }
    }
  }

  fileprivate static func textColor(for tone: MessageServiceDisplaySegment.Tone) -> NSColor {
    switch tone {
      case .primary:
        .labelColor
      case .secondary:
        .secondaryLabelColor
      case .tertiary:
        .tertiaryLabelColor
    }
  }

  fileprivate static let font = ServiceMessageRowLayout.font
}

private final class ServiceMessageTextView: NSView {
  private struct LinkRun {
    let range: NSRange
    let link: MessageServiceDisplaySegment.Link
  }

  private let textStorage = NSTextStorage()
  private let layoutManager = NSLayoutManager()
  private let textContainer = NSTextContainer(size: .zero)
  private let onOpen: (MessageServiceDisplaySegment.Link) -> Void
  private var linkRuns: [LinkRun] = []

  override var isFlipped: Bool {
    true
  }

  init(onOpen: @escaping (MessageServiceDisplaySegment.Link) -> Void) {
    self.onOpen = onOpen
    super.init(frame: .zero)

    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = .byCharWrapping
    textContainer.widthTracksTextView = false
    textContainer.heightTracksTextView = false
    layoutManager.usesFontLeading = true
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setSegments(_ segments: [MessageServiceDisplaySegment], leading: Bool) {
    let text = NSMutableAttributedString()
    var runs: [LinkRun] = []

    for segment in segments where segment.text.isEmpty == false {
      let start = text.length
      text.append(NSAttributedString(
        string: segment.text,
        attributes: Self.attributes(for: segment.tone, leading: leading)
      ))

      if let link = segment.link {
        let range = NSRange(location: start, length: text.length - start)
        runs.append(LinkRun(range: range, link: link))
      }
    }

    textStorage.setAttributedString(text)
    linkRuns = runs
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    syncContainer(width: bounds.width)
    let glyphRange = layoutManager.glyphRange(for: textContainer)
    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    guard bounds.contains(localPoint), link(at: localPoint) != nil else { return nil }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let link = link(at: point) else {
      super.mouseDown(with: event)
      return
    }

    onOpen(link)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard !linkRuns.isEmpty else { return }

    syncContainer(width: bounds.width)
    layoutManager.ensureLayout(for: textContainer)
    for run in linkRuns {
      let glyphRange = layoutManager.glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
      layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
        let range = NSIntersectionRange(glyphRange, lineGlyphRange)
        guard range.length > 0 else { return }

        let rect = self.layoutManager.boundingRect(forGlyphRange: range, in: self.textContainer)
          .insetBy(dx: -1, dy: -2)
        self.addCursorRect(rect, cursor: .pointingHand)
      }
    }
  }

  private func syncContainer(width: CGFloat) {
    let next = NSSize(width: max(1, floor(width)), height: CGFloat.greatestFiniteMagnitude)
    guard textContainer.containerSize != next else { return }

    textContainer.containerSize = next
    layoutManager.invalidateLayout(
      forCharacterRange: NSRange(location: 0, length: textStorage.length),
      actualCharacterRange: nil
    )
  }

  private func link(at point: NSPoint) -> MessageServiceDisplaySegment.Link? {
    guard textStorage.length > 0 else { return nil }

    syncContainer(width: bounds.width)
    layoutManager.ensureLayout(for: textContainer)
    let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
    guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

    let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
      .insetBy(dx: -2, dy: -2)
    guard lineRect.contains(point) else { return nil }

    let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    return linkRuns.first { NSLocationInRange(charIndex, $0.range) }?.link
  }

  private static func attributes(
    for tone: MessageServiceDisplaySegment.Tone,
    leading: Bool
  ) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = leading ? .left : .center
    paragraphStyle.lineBreakMode = .byCharWrapping

    return [
      .font: ServiceMessageViewAppKit.font,
      .foregroundColor: ServiceMessageViewAppKit.textColor(for: tone),
      .paragraphStyle: paragraphStyle,
    ]
  }
}
