@testable import InlineIOS
@testable import InlineKit
import Testing
import UIKit

@Suite("Chat Dynamic Type", .serialized)
@MainActor
struct ChatMessageTextSizeTests {
  @Test("Both message renderers rebuild cached text at the selected size", arguments: [false, true])
  func messageFonts(v2: Bool) throws {
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = "Readable text with enough words to wrap into several lines at a larger size."
    message.message.entities = nil
    message.message.blockContentPayload = nil
    let theme = ThemeManager.shared.snapshot(variant: .light)
    let view: UIMessageView = v2
      ? UIMessageView2(fullMessage: message, spaceId: nil, displayMode: .normal, bubbleTailSide: .none,
                      maximumBubbleContentWidth: 280, theme: theme)
      : UIMessageView(fullMessage: message, spaceId: nil, maximumBubbleContentWidth: 280, theme: theme)

    func font(at category: UIContentSizeCategory) throws -> UIFont {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      let text = try #require(view.attributedMessageText())
      return try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    }

    let normal = try font(at: .large)
    let large = try font(at: .accessibilityExtraExtraExtraLarge)
    #expect(normal.pointSize == 17)
    #expect(large.pointSize > normal.pointSize)
    #expect(try font(at: .large).pointSize == normal.pointSize)
  }

  @Test("Unchanged messages are reconfigured after changing text size", arguments: [false, true])
  func unchangedCell(v2: Bool) throws {
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = "A message that is already on screen"
    message.message.blockContentPayload = nil
    let cell = MessageCollectionViewCell(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
    func configure() {
      cell.configure(
        with: message, firstInGroup: true, lastInGroup: true, spaceId: nil,
        collectionWidth: 320, theme: ThemeManager.shared.snapshot(variant: .light),
        messageViewImplementation: v2 ? .v2 : .legacy
      )
    }
    cell.traitOverrides.preferredContentSizeCategory = .large
    cell.updateTraitsIfNeeded()
    configure()
    let first = try #require(cell.messageView)
    configure()
    #expect(cell.messageView === first)
    cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    cell.updateTraitsIfNeeded()
    configure()
    #expect(cell.messageView !== first)
  }

  @Test("Status symbols grow with the timestamp in every delivery state", arguments: [MessageSendingStatus.sent, .sending, .failed])
  func statusSymbols(status: MessageSendingStatus) throws {
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.out = true
    message.message.status = status
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let view = MessageTimeAndStatus(message)
    controller.view.addSubview(view)
    let symbol = try #require(view.subviews.compactMap { $0 as? UIImageView }.first)
    let label = try #require(view.subviews.compactMap { $0 as? UILabel }.first)
    var previousWidth: CGFloat = 0
    for category in [UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
      view.layoutIfNeeded()
      #expect(symbol.bounds.width >= previousWidth)
      #expect(abs(symbol.bounds.width - label.font.pointSize) < 1)
      #expect(symbol.frame.maxX <= view.bounds.maxX + 1)
      #expect(symbol.frame.minY >= -1)
      #expect(symbol.frame.maxY <= view.bounds.maxY + 1)
      previousWidth = symbol.bounds.width
    }
    #expect(previousWidth > 11)
  }

  @Test("Reply measurements use the selected category")
  func replyMeasurements() {
    let normal = UITraitCollection(preferredContentSizeCategory: .large)
    let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    #expect(EmbedMessageView.height(compatibleWith: largest) > EmbedMessageView.height(compatibleWith: normal))
  }

  @Test("Ordinary reply previews keep one truncated line in Persian and English", arguments: [
    "A long English reply preview with enough words to truncate at every tested text size.",
    "این یک پیش‌نمایش پاسخ فارسی طولانی است که باید در یک خط نمایش داده شود و ادامهٔ آن کوتاه شود.",
  ])
  func replyLabelsFit(text: String) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = text
    message.message.entities = nil
    message.message.blockContentPayload = nil
    let view = EmbedMessageView()
    controller.view.addSubview(view)
    view.configure(fullMessage: message, kind: .replyInMessage)
    for category in [UIContentSizeCategory.extraSmall, .large, .accessibilityExtraExtraExtraLarge] {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      view.frame = CGRect(x: 0, y: 0, width: 280,
                          height: EmbedMessageView.height(compatibleWith: view.traitCollection))
      view.layoutIfNeeded()
      let header = try #require(view.subviews.compactMap { $0 as? UILabel }.first)
      let body = try #require(view.subviews.compactMap { $0 as? UIStackView }.first?
        .arrangedSubviews.compactMap { $0 as? UILabel }.first)
      #expect(body.text == text)
      #expect(body.numberOfLines == 1)
      #expect(body.lineBreakMode == .byTruncatingTail)
      let expectedFont = ChatTypography.font(14, compatibleWith: view.traitCollection)
      #expect(abs(body.font.pointSize - expectedFont.pointSize) < 0.1)
      #expect((text as NSString).size(withAttributes: [.font: body.font!]).width > body.bounds.width)
      // Telegram's ordinary reply uses floor(nearestSupportedBodySize * 14 / 17),
      // one line, end truncation and natural alignment in both languages.
      let systemBody = UIFont.preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection).pointSize
      let telegramBody = [14.0, 15, 16, 17, 19, 23, 26].min { abs($0 - systemBody) < abs($1 - systemBody) }!
      print("Reply comparison: category=\(category.rawValue), Persian=\(text.hasPrefix("این")), Inline=\(body.font.pointSize), Telegram source policy=\(floor(telegramBody * 14 / 17)), one truncated line")
      for label in [header, body] {
        let frame = label.convert(label.bounds, to: view)
        #expect(frame.minY >= -1 && frame.maxY <= view.bounds.height + 1)
        #expect(label.bounds.height + 1 >= label.font.lineHeight)
      }
    }
  }

  @Test("A retained plain bubble moves metadata to a new line and back")
  func metadataReflow() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = "Readable message"
    message.message.entities = nil
    message.message.blockContentPayload = nil
    message.message.out = true
    let view = UIMessageView(fullMessage: message, spaceId: nil, maximumBubbleContentWidth: 280,
                             theme: ThemeManager.shared.snapshot(variant: .light))
    controller.view.addSubview(view)
    for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge, .large] {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      #expect(view.isMultiline == (category != .large))
      #expect((view.multiLineContainer.superview != nil) == (category != .large))
      #expect((view.singleLineContainer.superview != nil) == (category == .large))
      #expect(view.messageLabel.text == message.message.text)
    }
  }

  @Test("Standalone emoji retain their presentation size", arguments: [false, true])
  func emojiSize(v2: Bool) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = "😀"
    message.message.entities = nil
    message.message.blockContentPayload = nil
    let theme = ThemeManager.shared.snapshot(variant: .light)
    let view: UIMessageView = v2
      ? UIMessageView2(fullMessage: message, spaceId: nil, displayMode: .normal, bubbleTailSide: .none, maximumBubbleContentWidth: 280, theme: theme)
      : UIMessageView(fullMessage: message, spaceId: nil, maximumBubbleContentWidth: 280, theme: theme)
    controller.view.addSubview(view)
    for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      #expect(view.messageBodyFont.pointSize == 80)
      let measured = view.systemLayoutSizeFitting(
        CGSize(width: 350, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
      )
      view.frame = CGRect(origin: .zero, size: measured)
      view.layoutIfNeeded()
      let metadataFrame = view.floatingMetadataView.convert(view.floatingMetadataView.bounds, to: view)
      #expect(metadataFrame.minY >= -1)
      #expect(metadataFrame.maxY <= view.bounds.height + 1)
      #expect(metadataFrame.minX >= -1)
      #expect(metadataFrame.maxX <= view.bounds.width + 1)
    }
  }

  @Test("Narrow outgoing emoji keep metadata and acknowledgements clear", arguments: [false, true])
  func narrowEmojiAcknowledgement(v2: Bool) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    for width: CGFloat in [180, 240, 320, 375] {
      for actorCount in [1, 3, 5] {
        var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
        message.message.text = "😀"
        message.message.entities = nil
        message.message.blockContentPayload = nil
        message.message.out = true
        message.reactions = []
        message.acknowledgements = (1 ... actorCount).map { id in
          FullAcknowledgement(acknowledgement: Acknowledgement(
            chatId: message.message.chatId, userId: Int64(id), maxId: message.message.messageId
          ))
        }
        let theme = ThemeManager.shared.snapshot(variant: .light)
        let view: UIMessageView = v2
          ? UIMessageView2(fullMessage: message, spaceId: nil, displayMode: .normal,
                          bubbleTailSide: .none, maximumBubbleContentWidth: width * 0.8, theme: theme)
          : UIMessageView(fullMessage: message, spaceId: nil,
                          maximumBubbleContentWidth: width * 0.8, theme: theme)
        controller.view.addSubview(view)
        view.updateTraitsIfNeeded()
        let size = view.systemLayoutSizeFitting(
          CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
          withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let metadata = view.floatingMetadataView.convert(view.floatingMetadataView.bounds, to: view)
        let acknowledgement = view.acknowledgementView.convert(view.acknowledgementView.bounds, to: view)
        let bubble = view.bubbleView.contentView.convert(view.bubbleView.contentView.bounds, to: view)
        #expect(metadata.minX >= bubble.minX - 1 && metadata.maxX <= bubble.maxX + 1,
                "Metadata exceeds bubble width: width=\(width), actors=\(actorCount), v2=\(v2)")
        let label = view.messageLabel
        label.layoutManager.ensureLayout(for: label.textContainer)
        let glyphs = label.layoutManager.glyphRange(for: label.textContainer)
        let ink = label.layoutManager.boundingRect(forGlyphRange: glyphs, in: label.textContainer)
          .offsetBy(dx: label.textContainerInset.left, dy: label.textContainerInset.top)
        let emoji = label.convert(ink, to: view)
        for frame in [metadata, acknowledgement] {
          #expect(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "width=\(width), actors=\(actorCount), v2=\(v2), frame=\(frame)")
          #expect(!frame.intersects(emoji), "Accessory overlaps emoji: width=\(width), actors=\(actorCount), v2=\(v2)")
        }
        #expect(!metadata.intersects(acknowledgement))
        #expect(view.messageBodyFont.pointSize == 80)
        view.removeFromSuperview()
      }
    }
  }

  @Test("An open list reflows Persian and English and stays at the bottom", arguments: [false, true])
  func liveListReflow(v2: Bool) async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    controller.traitOverrides.preferredContentSizeCategory = .large
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database)
    let peer = Peer.user(id: 9_007)
    let template = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    let rows = (1 ... 30).reversed().map { id -> FullMessage in
      var row = template
      row.message.globalId = 90_000 + Int64(id)
      row.message.messageId = Int64(id)
      row.message.chatId = 9_007
      row.message.peerThreadId = nil
      row.message.peerUserId = 9_007
      row.message.date = template.message.date.addingTimeInterval(Double(id))
      row.message.text = id.isMultiple(of: 2)
        ? "سلام، اندازهٔ متن این پیام باید با تنظیمات گوشی تغییر کند."
        : "Readable text that wraps as the preferred text size changes."
      row.message.entities = nil
      row.message.blockContentPayload = nil
      return row
    }
    let model = MessagesSectionedViewModel(
      peer: peer, reversed: true,
      initialState: .init(messages: rows,
        loadedWindowMetadata: MessagesProgressiveViewModel.unknownLoadedWindowMetadata(for: rows)),
      database: database, publisher: publisher
    )
    defer { model.dispose() }
    let list = MessagesCollectionView(
      peerId: peer, chatId: 9_007, spaceId: nil, isPreview: true,
      theme: ThemeManager.shared.snapshot(variant: .light), viewModel: model,
      messageViewImplementation: v2 ? .v2 : .legacy
    )
    list.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
    controller.view.addSubview(list)
    list.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    list.setContentOffset(CGPoint(x: 0, y: -list.contentInset.top), animated: false)
    var normalHeight: CGFloat = 0
    for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge, .extraSmall] {
      controller.traitOverrides.preferredContentSizeCategory = category
      controller.view.updateTraitsIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      list.layoutIfNeeded()
      let cells = list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      try #require(!cells.isEmpty)
      for cell in cells {
        let view = try #require(cell.messageView)
        let text = try #require(view.messageLabel.attributedText)
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let expected = UIFont.preferredFont(forTextStyle: .body,
          compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        #expect(abs(font.pointSize - expected.pointSize) < 0.1)
        #expect(view.messageLabel.bounds.height + 1 >= font.lineHeight)
        let textView = view.messageLabel
        let requiredSize = textView.sizeThatFits(CGSize(
          width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude
        ))
        #expect(requiredSize.height <= textView.bounds.height + 1)
      }
      let first = try #require(cells.first { $0.message?.message.messageId == 30 })
      if category == .large { normalHeight = first.bounds.height }
      if category == .accessibilityExtraExtraExtraLarge { #expect(first.bounds.height > normalHeight) }
      #expect(abs(list.contentOffset.y + list.contentInset.top) < 1)
    }
    // A reader in older history should keep the same visible row and offset.
    list.contentOffset.y = max(0, (list.contentSize.height - list.bounds.height) / 2)
    list.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let viewport = list.bounds.inset(by: list.adjustedContentInset)
    let anchor = try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .min { abs($0.frame.minY - viewport.midY) < abs($1.frame.minY - viewport.midY) })
    let anchorID = try #require(anchor.message?.id)
    let offset = anchor.frame.minY - list.contentOffset.y
    controller.traitOverrides.preferredContentSizeCategory = .extraLarge
    controller.view.updateTraitsIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    list.layoutIfNeeded()
    let updatedAnchor = try #require(list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      .first { $0.message?.id == anchorID })
    #expect(abs(updatedAnchor.frame.minY - list.contentOffset.y - offset) < 2)
    // Scroll the latest rows fully offscreen, change size in older history,
    // then return them to the viewport. This exercises the real reuse path.
    let latestIDs = Set(list.visibleCells.compactMap { ($0 as? MessageCollectionViewCell)?.message?.id })
    list.contentOffset.y = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
    list.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let olderIDs = Set(list.visibleCells.compactMap { ($0 as? MessageCollectionViewCell)?.message?.id })
    #expect(!olderIDs.isEmpty)
    #expect(olderIDs != latestIDs)
    controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    controller.view.updateTraitsIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    list.layoutIfNeeded()
    for offsetY in [list.contentOffset.y, -list.contentInset.top] {
      list.setContentOffset(CGPoint(x: 0, y: offsetY), animated: false)
      list.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let visible = list.visibleCells.compactMap { $0 as? MessageCollectionViewCell }
      try #require(!visible.isEmpty)
      for cell in visible {
        let view = try #require(cell.messageView)
        let rendered = try #require(view.messageLabel.attributedText)
        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let expected = UIFont.preferredFont(forTextStyle: .body,
          compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        #expect(abs(font.pointSize - expected.pointSize) < 0.1)
        #expect(view.messageLabel.sizeThatFits(CGSize(width: view.messageLabel.bounds.width,
          height: CGFloat.greatestFiniteMagnitude)).height <= view.messageLabel.bounds.height + 1)
      }
    }
    #expect(list.visibleCells.compactMap { ($0 as? MessageCollectionViewCell)?.message?.message.messageId }.contains(30))
    list.removeFromSuperview()
  }

}
