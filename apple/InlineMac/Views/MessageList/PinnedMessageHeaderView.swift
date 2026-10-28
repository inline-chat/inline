import AppKit
import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI
import Translation
import os.signpost

private let pinnedHeaderCornerRadius: CGFloat = 14

final class PinnedMessageHeaderView: NSView {
  private enum Constants {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 2
    static let contentSpacing: CGFloat = 8
    static let closeButtonSize: CGFloat = EmbedMessageView.height
    static let fadeDuration: TimeInterval = 0.2
    static let swapDuration: TimeInterval = 0.18
    static let stripeLeadingInset: CGFloat = 12
    static let stripeWidth: CGFloat = 2
    static let stripeTextSpacing: CGFloat = 6
  }

  static let preferredHeight: CGFloat = EmbedMessageView.height + (Constants.verticalPadding * 2)

  private let peerId: Peer
  private let chatId: Int64
  private let dependencies: AppDependencies
  private let log = Log.scoped("PinnedMessageHeaderView")
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  var onHeightChange: ((CGFloat) -> Void)?

  private var pinnedMessageObservation: AnyCancellable?
  private var messageObservation: AnyCancellable?
  private var bar = PinnedMessageBar()
  private var currentMessageId: Int64? { bar.displayedMessageId }

  private let backgroundView: NSView
  private let backgroundContentView: NSView
  private var didStartObservation = false

  private lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.showsBackground = false
    view.showsLeadingBar = false
    view.textLeadingPadding = Constants.horizontalPadding
    view.textTrailingPadding = Constants.horizontalPadding
    view.wantsLayer = true
    view.onTap = { [weak self] in
      self?.primaryTapped()
    }
    return view
  }()

  private let stripeView: PinnedMessageStripeView = {
    let view = PinnedMessageStripeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    return view
  }()

  private lazy var closeButton: HoverHighlightButton = {
    let button = HoverHighlightButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .inline
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Unpin")
    button.target = self
    button.action = #selector(unpinTapped)
    button.toolTip = "Unpin"
    return button
  }()

  private var backgroundViewTopConstraint: NSLayoutConstraint?
  private var backgroundViewBottomConstraint: NSLayoutConstraint?
  private var closeButtonHeightConstraint: NSLayoutConstraint?
  private var isVisible = false

  init(
    dependencies: AppDependencies,
    peerId: Peer,
    chatId: Int64,
    initialPinnedMessage: PreparedPinnedMessage? = nil
  ) {
    self.dependencies = dependencies
    self.peerId = peerId
    self.chatId = chatId
    if #available(macOS 26.0, *) {
      let glassView = PinnedMessageGlassBackgroundView(cornerRadius: pinnedHeaderCornerRadius)
      backgroundView = glassView
      backgroundContentView = glassView
    } else {
      let glassView = NSVisualEffectView()
      glassView.translatesAutoresizingMaskIntoConstraints = false
      glassView.material = .hudWindow
      glassView.blendingMode = .withinWindow
      glassView.state = .active
      glassView.wantsLayer = true
      glassView.layer?.cornerRadius = pinnedHeaderCornerRadius
      glassView.layer?.masksToBounds = true
      glassView.layer?.borderWidth = 0
      glassView.layer?.borderColor = nil
      backgroundView = glassView
      backgroundContentView = glassView
    }
    super.init(frame: .zero)
    setupView()
    setupConstraints()
    if let initialPinnedMessage {
      applyInitialPinnedMessage(initialPinnedMessage)
    } else {
      applyHiddenState()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)
    backgroundContentView.addSubview(stripeView)
    backgroundContentView.addSubview(embedView)
    backgroundContentView.addSubview(closeButton)
    isHidden = true
  }

  private func setupConstraints() {
    backgroundViewTopConstraint = backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding)
    backgroundViewBottomConstraint = backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.verticalPadding)
    closeButtonHeightConstraint = closeButton.heightAnchor.constraint(equalToConstant: Constants.closeButtonSize)
    let closeButtonTrailingConstraint = closeButton.trailingAnchor.constraint(
      equalTo: backgroundContentView.trailingAnchor,
      constant: -Constants.horizontalPadding
    )
    closeButtonTrailingConstraint.priority = .defaultHigh

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalPadding),
      backgroundViewTopConstraint!,
      backgroundViewBottomConstraint!,

      stripeView.leadingAnchor.constraint(
        equalTo: backgroundContentView.leadingAnchor,
        constant: Constants.stripeLeadingInset
      ),
      stripeView.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      stripeView.widthAnchor.constraint(equalToConstant: Constants.stripeWidth),
      stripeView.heightAnchor.constraint(equalToConstant: EmbedMessageView.height - 8),

      embedView.leadingAnchor.constraint(equalTo: backgroundContentView.leadingAnchor, constant: Constants.horizontalPadding),
      embedView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -Constants.contentSpacing),
      embedView.centerYAnchor.constraint(equalTo: backgroundContentView.centerYAnchor),
      closeButtonTrailingConstraint,
      closeButton.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: Constants.closeButtonSize),
      closeButtonHeightConstraint!,
    ])
  }


  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      self?.startObservingIfNeeded()
    }
  }

  private func startObservingIfNeeded() {
    guard !didStartObservation else { return }
    didStartObservation = true
    let signpostID = OSSignpostID(log: Self.signpostLog)
    os_signpost(
      .begin,
      log: Self.signpostLog,
      name: "PinnedHeaderStartObserving",
      signpostID: signpostID,
      "%{public}s",
      "chatId=\(chatId)"
    )
    defer {
      os_signpost(.end, log: Self.signpostLog, name: "PinnedHeaderStartObserving", signpostID: signpostID)
    }

    observePinnedMessages()
    if let currentMessageId, messageObservation == nil {
      observePinnedMessageContent(messageId: currentMessageId)
    }
  }

  private func observePinnedMessages() {
    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("PinnedMessageHeaderView.pinnedMessage")
    pinnedMessageObservation = ValueObservation
      .tracking { [chatId] db in
        try PinnedMessage
          .filter(PinnedMessage.Columns.chatId == chatId)
          .select(PinnedMessage.Columns.messageId, as: Int64.self)
          .fetchAll(db)
          .sorted()
      }
      .removeDuplicates()
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Pinned message observation failed: \(completion)")
        },
        receiveValue: { [weak self] messageIds in
          self?.updatePinnedMessageIds(messageIds)
        }
      )
  }

  private func updatePinnedMessageIds(_ messageIds: [Int64]) {
    var next = bar
    next.update(messageIds: messageIds)
    applyBar(next)
  }

  private func applyBar(_ next: PinnedMessageBar, animated: Bool = true) {
    let previousMessageId = bar.displayedMessageId
    bar = next
    updatePinCountPresentation(animated: animated)

    guard next.displayedMessageId != previousMessageId else {
      embedView.pinnedHeaderTitle = next.title
      return
    }

    messageObservation?.cancel()
    messageObservation = nil

    guard let messageId = next.displayedMessageId else {
      setVisible(false)
      return
    }

    setVisible(true)
    if animated, previousMessageId != nil, window != nil,
       !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = Constants.swapDuration
      embedView.layer?.add(transition, forKey: "pinnedMessageSwap")
    }
    embedView.pinnedHeaderTitle = next.title
    if let message = loadPinnedMessage(messageId: messageId) {
      configurePinnedMessage(message)
    } else {
      showPinnedMessageUnavailable(messageId: messageId, shouldFetch: true)
    }
    observePinnedMessageContent(messageId: messageId)
  }

  private func applyInitialPinnedMessage(_ pinned: PreparedPinnedMessage) {
    bar = PinnedMessageBar(messageIds: pinned.messageIds)
    bar.show(pinned.messageId)
    updatePinCountPresentation(animated: false)
    embedView.pinnedHeaderTitle = bar.title
    setVisible(true, animate: false)

    if let message = pinned.message {
      configurePinnedMessage(message)
    } else {
      showPinnedMessageUnavailable(messageId: pinned.messageId, shouldFetch: true)
    }
  }

  /// The stripe, title and trailing button follow how many pins the chat has.
  private func updatePinCountPresentation(animated: Bool) {
    let hasSeveral = bar.count > 1
    stripeView.update(
      range: bar.visibleStripeRange,
      selectedIndex: bar.displayedIndex,
      animated: animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    stripeView.isHidden = !hasSeveral
    embedView.textLeadingPadding = hasSeveral
      ? Constants.stripeLeadingInset + Constants.stripeWidth + Constants.stripeTextSpacing - Constants.horizontalPadding
      : Constants.horizontalPadding

    if let index = bar.displayedIndex, hasSeveral {
      embedView.setAccessibilityValue("\(index + 1) of \(bar.count)")
    } else {
      embedView.setAccessibilityValue(nil)
    }

    let symbolName = hasSeveral ? "list.bullet" : "xmark"
    let label = hasSeveral ? "Pinned Messages" : "Unpin"
    guard closeButton.toolTip != label else { return }
    closeButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
    closeButton.toolTip = label
  }

  private func configurePinnedMessage(_ message: FullMessage) {
    embedView.configure(
      fullMessage: message,
      kind: .pinnedInHeader,
      outgoing: false,
      isOnlyEmoji: false,
      style: .replyBubble
    )
  }

  private func showPinnedMessageUnavailable(messageId: Int64? = nil, shouldFetch: Bool = false) {
    embedView.showNotLoaded(
      kind: .pinnedInHeader,
      outgoing: false,
      isOnlyEmoji: false,
      style: .replyBubble,
      messageText: "Pinned message unavailable"
    )

    guard shouldFetch, let messageId else { return }
    Task {
      await TargetMessagesFetcher.shared.ensureCached(peer: peerId, chatId: chatId, messageIds: [messageId])
    }
  }

  private func loadPinnedMessage(messageId: Int64) -> FullMessage? {
    let signpostID = OSSignpostID(log: Self.signpostLog)
    var found = false
    os_signpost(
      .begin,
      log: Self.signpostLog,
      name: "PinnedHeaderLoadMessage",
      signpostID: signpostID,
      "%{public}s",
      "chatId=\(chatId)"
    )
    defer {
      os_signpost(
        .end,
        log: Self.signpostLog,
        name: "PinnedHeaderLoadMessage",
        signpostID: signpostID,
        "%{public}s",
        "found=\(found)"
      )
    }

    do {
      let message = try AppDatabase.shared.dbWriter.read { db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == messageId && Column("chatId") == chatId
          )
          .fetchOne(db)
      }
      found = message != nil
      return message
    } catch {
      log.error("Failed to read pinned message state", error: error)
      return nil
    }
  }

  private func observePinnedMessageContent(messageId: Int64) {
    AppDatabase.shared.warnIfInMemoryDatabaseForObservation("PinnedMessageHeaderView.pinnedMessageContent")
    messageObservation = ValueObservation
      .tracking { [chatId] db in
        try FullMessage.queryRequest()
          .filter(
            Column("messageId") == messageId && Column("chatId") == chatId
          )
          .fetchOne(db)
      }
      .publisher(in: AppDatabase.shared.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Pinned message fetch failed: \(completion)")
        },
        receiveValue: { [weak self] message in
          guard let self else { return }
          if let message {
            configurePinnedMessage(message)
          } else {
            showPinnedMessageUnavailable()
          }
        }
      )
  }

  private func setVisible(_ visible: Bool, animate: Bool = true) {
    guard visible != isVisible else { return }
    let signpostID = OSSignpostID(log: Self.signpostLog)
    os_signpost(
      .begin,
      log: Self.signpostLog,
      name: "PinnedHeaderSetVisible",
      signpostID: signpostID,
      "%{public}s",
      "visible=\(visible) animate=\(animate) hasWindow=\(window != nil)"
    )
    defer {
      os_signpost(.end, log: Self.signpostLog, name: "PinnedHeaderSetVisible", signpostID: signpostID)
    }

    isVisible = visible

    let canAnimate = animate && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    if visible {
      isHidden = false
      alphaValue = canAnimate ? 0 : 1
      backgroundViewTopConstraint?.constant = Constants.verticalPadding
      backgroundViewBottomConstraint?.constant = -Constants.verticalPadding
      embedView.setCollapsed(false)
      closeButtonHeightConstraint?.constant = Constants.closeButtonSize
      onHeightChange?(Self.preferredHeight)
      superview?.layoutSubtreeIfNeeded()

      guard canAnimate else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Constants.fadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        animator().alphaValue = 1
      }
    } else {
      guard canAnimate else {
        applyHiddenState()
        return
      }

      alphaValue = 1
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Constants.fadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        animator().alphaValue = 0
      } completionHandler: { [weak self] in
        guard let self, !self.isVisible else { return }
        self.applyHiddenState()
      }
    }
  }

  private func applyHiddenState() {
    isHidden = true
    alphaValue = 0
    backgroundViewTopConstraint?.constant = 0
    backgroundViewBottomConstraint?.constant = 0
    embedView.setCollapsed(true)
    closeButtonHeightConstraint?.constant = 0
    onHeightChange?(0)
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    guard currentMessageId != nil else { return nil }

    let menu = NSMenu()
    menu.addItem(contextMenuItem(
      title: "Go to Message",
      systemSymbolName: "text.bubble",
      action: #selector(goToMessage)
    ))
    menu.addItem(contextMenuItem(
      title: "Unpin",
      systemSymbolName: "pin.slash",
      action: #selector(unpinShown)
    ))
    if bar.count > 1 {
      menu.addItem(contextMenuItem(
        title: "Unpin All \(bar.count) Messages…",
        systemSymbolName: "pin.slash",
        action: #selector(confirmUnpinAll)
      ))
    }
    return menu
  }

  /// Every pin, newest first, then the unpin actions. Opened from the trailing button when there are several.
  private func pinnedListMenu() -> NSMenu {
    let menu = NSMenu()
    let messageIds = bar.messageIds
    let messages = loadPinnedMessages(messageIds: messageIds)
    let missing = messageIds.filter { messages[$0] == nil }
    if !missing.isEmpty {
      Task { [peerId, chatId] in
        await TargetMessagesFetcher.shared.ensureCached(peer: peerId, chatId: chatId, messageIds: missing)
      }
    }

    for messageId in messageIds.reversed() {
      let item = NSMenuItem(
        title: messages[messageId].map(Self.menuTitle) ?? "Pinned message unavailable",
        action: #selector(openPinFromMenu(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = Int(messageId)
      item.state = messageId == bar.displayedMessageId ? .on : .off
      menu.addItem(item)
    }

    menu.addItem(.separator())
    menu.addItem(contextMenuItem(
      title: "Unpin",
      systemSymbolName: "pin.slash",
      action: #selector(unpinShown)
    ))
    menu.addItem(contextMenuItem(
      title: "Unpin All \(messageIds.count) Messages…",
      systemSymbolName: "pin.slash",
      action: #selector(confirmUnpinAll)
    ))
    return menu
  }

  private static func menuTitle(_ message: FullMessage) -> String {
    let text = (message.displayTextForLastMessage ?? message.message.stringRepresentationWithEmoji)
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let preview = text.count > 60 ? "\(text.prefix(60))…" : text
    guard let sender = message.from?.shortDisplayName else { return preview }
    return "\(sender): \(preview)"
  }

  private func loadPinnedMessages(messageIds: [Int64]) -> [Int64: FullMessage] {
    do {
      let messages = try AppDatabase.shared.dbWriter.read { [chatId] db in
        try FullMessage.queryRequest()
          .filter(Column("chatId") == chatId && messageIds.contains(Column("messageId")))
          .fetchAll(db)
      }
      return Dictionary(messages.map { ($0.message.messageId, $0) }, uniquingKeysWith: { first, _ in first })
    } catch {
      log.error("Failed to read pinned messages", error: error)
      return [:]
    }
  }

  private func contextMenuItem(title: String, systemSymbolName: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: title)
#if compiler(>=6.4)
    if #available(macOS 27.0, *) {
      item.preferredImageVisibility = .visible
    }
#else
    // Xcode 26 doesn't expose macOS 27's typed image-visibility API.
    if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
      item.setValue(1, forKey: "preferredImageVisibility")
    }
#endif
    return item
  }

  @objc private func goToMessage() {
    guard let messageId = currentMessageId else { return }
    scrollTo(messageId)
  }

  /// Jumps to the shown pin and moves the header to the next older one.
  private func primaryTapped() {
    var next = bar
    guard let messageId = next.advance() else { return }
    applyBar(next)
    scrollTo(messageId)
  }

  @objc private func openPinFromMenu(_ sender: NSMenuItem) {
    var next = bar
    next.show(Int64(sender.tag))
    guard let messageId = next.advance() else { return }
    applyBar(next)
    scrollTo(messageId)
  }

  private func scrollTo(_ messageId: Int64) {
    ChatsManager.shared
      .get(for: peerId, chatId: chatId)
      .scrollTo(msgId: messageId, reason: .pinned)
  }

  @objc private func unpinTapped() {
    if bar.count > 1 {
      pinnedListMenu().popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: closeButton.isFlipped ? closeButton.bounds.maxY + 4 : -4),
        in: closeButton
      )
      return
    }
    unpinShown()
  }

  @objc private func unpinShown() {
    guard let messageId = currentMessageId else { return }
    unpin([messageId])
  }

  @objc private func confirmUnpinAll() {
    let messageIds = bar.messageIds
    guard !messageIds.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Unpin all \(messageIds.count) messages?"
    alert.informativeText = "They'll be unpinned for everyone in this chat."
    alert.addButton(withTitle: "Unpin All").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    let unpinAll: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.unpin(messageIds)
    }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: unpinAll)
    } else {
      unpinAll(alert.runModal())
    }
  }

  private func unpin(_ messageIds: [Int64]) {
    for messageId in messageIds {
      Task { @MainActor [dependencies, peerId] in
        do {
          _ = try await dependencies.realtimeV2.send(.pinMessage(peer: peerId, messageId: messageId, unpin: true))
        } catch {
          Log.shared.error("Failed to unpin message", error: error)
        }
      }
    }
  }
}

/// Telegram-style position indicator: one segment per pin in chat order, the shown pin highlighted.
private final class PinnedMessageStripeView: NSView {
  private static let segmentSpacing: CGFloat = 2

  private var segmentLayers: [CALayer] = []
  private var range: Range<Int> = 0 ..< 0
  private var selectedIndex: Int?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  func update(range: Range<Int>, selectedIndex: Int?, animated: Bool) {
    self.range = range
    self.selectedIndex = selectedIndex

    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    while segmentLayers.count < range.count {
      let segment = CALayer()
      segment.cornerRadius = 1
      layer?.addSublayer(segment)
      segmentLayers.append(segment)
    }
    while segmentLayers.count > range.count {
      segmentLayers.removeLast().removeFromSuperlayer()
    }
    applyColors()
    layoutSegments()
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layoutSegments()
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      for (offset, segment) in segmentLayers.enumerated() {
        let isSelected = range.lowerBound + offset == selectedIndex
        segment.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isSelected ? 1 : 0.3).cgColor
      }
    }
  }

  private func layoutSegments() {
    guard !segmentLayers.isEmpty else { return }
    let count = CGFloat(segmentLayers.count)
    let height = max(0, (bounds.height - Self.segmentSpacing * (count - 1)) / count)
    for (offset, segment) in segmentLayers.enumerated() {
      segment.frame = CGRect(
        x: 0,
        y: CGFloat(offset) * (height + Self.segmentSpacing),
        width: bounds.width,
        height: height
      )
    }
  }
}

private final class HoverHighlightButton: NSButton {
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet {
      updateAppearance()
    }
  }

  private let hoverLayer = CALayer()
  private let normalTintColor: NSColor = .secondaryLabelColor
  private let hoverTintColor: NSColor = .labelColor

  override init(frame: NSRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configure()
  }

  private func configure() {
    wantsLayer = true
    layer?.cornerRadius = pinnedHeaderCornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = false

    hoverLayer.cornerRadius = pinnedHeaderCornerRadius
    hoverLayer.cornerCurve = .continuous
    hoverLayer.backgroundColor = NSColor.clear.cgColor
    layer?.addSublayer(hoverLayer)

    updateAppearance()
  }

  override func layout() {
    super.layout()
    let size = min(bounds.width, bounds.height) * 0.7
    hoverLayer.frame = CGRect(
      x: (bounds.width - size) / 2,
      y: (bounds.height - size) / 2,
      width: size,
      height: size
    )
    hoverLayer.cornerRadius = min(pinnedHeaderCornerRadius, size / 2)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let options: NSTrackingArea.Options = [
      .activeInKeyWindow,
      .mouseEnteredAndExited,
      .inVisibleRect,
    ]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    let isDarkMode = effectiveAppearance.isDarkMode
    let hoverAlpha: CGFloat = isDarkMode ? 0.24 : 0.12
    let backgroundColor = isHovered ? NSColor.systemGray.withAlphaComponent(hoverAlpha) : .clear
    hoverLayer.backgroundColor = backgroundColor.cgColor
    contentTintColor = isHovered ? hoverTintColor : normalTintColor
  }
}

@available(macOS 26.0, *)
private final class PinnedMessageGlassBackgroundView: NSView {
  private let hostingView: NSHostingView<PinnedMessageGlassView>

  init(cornerRadius: CGFloat) {
    hostingView = NSHostingView(rootView: PinnedMessageGlassView(cornerRadius: cornerRadius))
    super.init(frame: .zero)

    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor

    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@available(macOS 26.0, *)
private struct PinnedMessageGlassView: View {
  let cornerRadius: CGFloat

  var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
      .allowsHitTesting(false)
  }
}
