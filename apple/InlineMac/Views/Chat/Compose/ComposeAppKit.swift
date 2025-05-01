import AppKit
import Combine
import InlineKit
import Logger
import SwiftUI

class ComposeAppKit: NSView {
  // Props
  private var peerId: Peer
  private var chat: Chat?
  private var chatId: Int64? { chat?.id }
  private var dependencies: AppDependencies

  // State
  weak var messageList: MessageListAppKit?
  private weak var viewModel: FullChatViewModel?

  // [uniqueId: FileMediaItem]
  private var attachmentItems: [String: FileMediaItem] = [:]

  // Internal
  private var heightConstraint: NSLayoutConstraint!
  private var textHeightConstraint: NSLayoutConstraint!
  private var minHeight = Theme.composeMinHeight + Theme.composeOuterSpacing
  private var radius: CGFloat = round(Theme.composeMinHeight / 2)
  private var horizontalOuterSpacing = Theme.composeOuterSpacing
  private var buttonsBottomSpacing = (Theme.composeMinHeight - Theme.composeButtonSize) / 2

  // ---
  private var textViewContentHeight: CGFloat = 0.0
  private var textViewHeight: CGFloat = 0.0

  // Features
  private var feature_animateHeightChanges = false // for now until fixing how to update list view smoothly

  func update(viewModel: FullChatViewModel) {
    self.viewModel = viewModel
  }

  // MARK: Views

  private lazy var textEditor: ComposeTextEditor = {
    let textEditor = ComposeTextEditor(initiallySingleLine: false)
    textEditor.translatesAutoresizingMaskIntoConstraints = false
    return textEditor
  }()

  private lazy var sendButton: ComposeSendButton = {
    let view = ComposeSendButton(
      frame: .zero,
      onSend: { [weak self] in
        self?.send()
      }
    )
    return view
  }()

  private lazy var menuButton: ComposeMenuButton = {
    let view = ComposeMenuButton()
    view.delegate = self
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  // Add reply view
  private lazy var replyView: ComposeReplyView = {
    let view = ComposeReplyView(
      kind: .replyingInCompose,
      onClose: { [weak self] in
        self?.state.clearReplyingToMsgId()
      }
    )

    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  // Add attachments view
  private lazy var attachments: ComposeAttachments = {
    let view = ComposeAttachments(frame: .zero, compose: self)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  lazy var border = {
    let border = NSBox()
    border.boxType = .separator
    border.translatesAutoresizingMaskIntoConstraints = false
    return border
  }()

  lazy var background = {
    // Add vibrancy effect
    let material = NSVisualEffectView(frame: bounds)
    material.material = .headerView
    material.blendingMode = .withinWindow
    material.state = .followsWindowActiveState
    material.translatesAutoresizingMaskIntoConstraints = false
    return material
  }()

  var hasTopSeperator: Bool = false

  // -------

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    // Focus the text editor
    focus()
  }

  // MARK: Initialization

  init(peerId: Peer, messageList: MessageListAppKit, chat: Chat?, dependencies: AppDependencies) {
    self.peerId = peerId
    self.messageList = messageList
    self.chat = chat
    self.dependencies = dependencies

    super.init(frame: .zero)
    setupView()
    setupObservers()
    setupKeyDownHandler()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Setup

  func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    // More distinct background
    // layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor

    // bg
    addSubview(background)
    addSubview(border)

    // from top
    addSubview(replyView)

    addSubview(attachments)

    // to bottom
    addSubview(sendButton)
    addSubview(menuButton)
    addSubview(textEditor)

    setupReplyingView()
    setUpConstraints()
    setupTextEditor()
  }

  private func setUpConstraints() {
    heightConstraint = heightAnchor.constraint(equalToConstant: minHeight)
    textHeightConstraint = textEditor.heightAnchor.constraint(equalToConstant: minHeight)

    let textViewHorizontalPadding = textEditor.horizontalPadding

    NSLayoutConstraint.activate([
      heightConstraint,

      // bg
      background.leadingAnchor.constraint(equalTo: leadingAnchor),
      background.trailingAnchor.constraint(equalTo: trailingAnchor),
      background.topAnchor.constraint(equalTo: topAnchor),
      background.bottomAnchor.constraint(equalTo: bottomAnchor),

      // send
      sendButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -horizontalOuterSpacing
      ),
      sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsBottomSpacing),

      // menu
      menuButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalOuterSpacing),
      menuButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsBottomSpacing),

      // reply (height handled internally)
      replyView.leadingAnchor.constraint(equalTo: textEditor.leadingAnchor, constant: textViewHorizontalPadding),
      replyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalOuterSpacing),

      // attachments
      attachments.leadingAnchor.constraint(equalTo: textEditor.leadingAnchor, constant: textViewHorizontalPadding),
      attachments.trailingAnchor.constraint(equalTo: textEditor.trailingAnchor),
      attachments.topAnchor.constraint(equalTo: replyView.bottomAnchor),

      // text editor
      textEditor.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor),
      textEditor.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),
      textHeightConstraint,
      textEditor.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Update text editor top constraint
      // textEditor.topAnchor.constraint(equalTo: topAnchor),
      textEditor.topAnchor.constraint(equalTo: attachments.bottomAnchor),

      // top seperator border
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.topAnchor.constraint(equalTo: topAnchor),
      border.heightAnchor.constraint(equalToConstant: 1),
    ])

    if hasTopSeperator {
      border.isHidden = false
    } else {
      border.isHidden = true
    }
  }

  private var cancellables: Set<AnyCancellable> = []
  private var state: ChatState {
    ChatsManager.get(for: peerId, chatId: chatId ?? 0)
  }

  func setupObservers() {
    state.replyingToMsgIdPublisher
      .sink { [weak self] replyingToMsgId in
        guard let self else { return }
        updateReplyingView(to: replyingToMsgId, animate: true)
        focus()
      }.store(in: &cancellables)
  }

  private func setupTextEditor() {
    // Set the delegate if needed
    textEditor.delegate = self
  }

  // MARK: - Public Interface

  var text: String {
    get { textEditor.string }
    set { textEditor.string = newValue }
  }

  func focusEditor() {
    textEditor.focus()
  }

  // MARK: - Height

  private func getTextViewHeight() -> CGFloat {
    textViewHeight = min(300.0, max(
      textEditor.minHeight,
      textViewContentHeight + textEditor.verticalPadding * 2
    ))

    return textViewHeight
  }

  // Get compose wrapper height
  private func getHeight() -> CGFloat {
    var height = getTextViewHeight()

    // Reply view
    if state.replyingToMsgId != nil {
      height += Theme.embeddedMessageHeight
    }

    // Attachments
    height += attachments.getHeight()

    return height
  }

  func updateHeight(animate: Bool = false) {
    let textEditorHeight = getTextViewHeight()
    let wrapperHeight = getHeight()

    if feature_animateHeightChanges || animate {
      // First update the height of scroll view immediately so it doesn't clip from top while animating
      CATransaction.begin()
      CATransaction.disableActions()
      textEditor.setHeight(textEditorHeight)
      CATransaction.commit()

      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true
        // Disable screen updates during animation setup
        // NSAnimationContext.beginGrouping()
        heightConstraint.animator().constant = wrapperHeight
        textHeightConstraint.animator().constant = textEditorHeight
        textEditor.updateTextViewInsets(contentHeight: textViewContentHeight) // use height without paddings
        attachments.updateHeight(animated: true)
        messageList?.updateInsetForCompose(wrapperHeight)
        // NSAnimationContext.endGrouping()
      }
    } else {
      textEditor.setHeight(textEditorHeight)
      textEditor.updateTextViewInsets(contentHeight: textViewContentHeight)
      heightConstraint.constant = wrapperHeight
      textHeightConstraint.constant = textEditorHeight
      attachments.updateHeight(animated: false)
      messageList?.updateInsetForCompose(wrapperHeight)
    }
  }

  private var ignoreNextHeightChange = false

  // MARK: - Reply View

  private func setupReplyingView() {
    if let replyingToMsgId = state.replyingToMsgId {
      print("setupReplyingView: \(replyingToMsgId)")
      updateReplyingView(to: replyingToMsgId, animate: false, shouldUpdateHeight: false)
    }
  }

  private var keyMonitorEscUnsubscribe: (() -> Void)? = nil
  private func addReplyEscHandler() {
    keyMonitorEscUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_reply_\(peerId)",
      handler: { [weak self] _ in
        guard let self else { return }
        state.clearReplyingToMsgId()
        removeReplyEscHandler()
      }
    )
  }

  private func removeReplyEscHandler() {
    keyMonitorEscUnsubscribe?()
    keyMonitorEscUnsubscribe = nil
  }

  private func updateReplyingView(to replyingToMsgId: Int64?, animate: Bool = false, shouldUpdateHeight: Bool = true) {
    if let replyingToMsgId {
      // Update and show the reply view
      if let message = try? FullMessage.get(messageId: replyingToMsgId, chatId: chatId ?? 0) {
        replyView.update(with: message)
        replyView.open(animated: animate)
        addReplyEscHandler()
      }
    } else {
      // Hide and remove the reply view
      replyView.close(animated: false)
      removeReplyEscHandler()
    }

    if shouldUpdateHeight {
      // Update height to accommodate the reply view
      updateHeight(animate: animate)
    }
  }

  // MARK: - Actions

  func addImage(_ image: NSImage) {
    do {
      // Save
      let photoInfo = try FileCache.savePhoto(image: image)
      let mediaItem = FileMediaItem.photo(photoInfo)
      let uniqueId = mediaItem.getItemUniqueId()

      // Update UI
      attachments.addImageView(image, id: uniqueId)
      updateHeight(animate: true)

      // Update State
      attachmentItems[uniqueId] = mediaItem
    } catch {
      Log.shared.error("Failed to save photo in attachments", error: error)
    }
  }

  func removeImage(_ id: String) {
    // TODO: Delete from cache as well

    // Update UI
    attachments.removeImageView(id: id)
    updateHeight(animate: true)

    // Update state
    attachmentItems.removeValue(forKey: id)
  }

  func addFile(_ url: URL) {
    do {
      let documentInfo = try FileCache.saveDocument(url: url)
      let mediaItem = FileMediaItem.document(documentInfo)
      let uniqueId = mediaItem.getItemUniqueId()

      // Update UI
      attachments.addDocumentView(documentInfo, id: uniqueId)
      updateHeight(animate: true)

      // Update State
      attachmentItems[uniqueId] = mediaItem
    } catch {
      Log.shared.error("Failed to save document", error: error)
    }
  }

  func removeFile(_ id: String) {
    // TODO: Delete from file cache as well

    // Update UI
    attachments.removeDocumentView(id: id)
    updateHeight(animate: true)

    // Update state
    attachmentItems.removeValue(forKey: id)
  }

  func clearAttachments(updateHeights: Bool = false) {
    attachmentItems.removeAll()
    attachments.clearViews()
    if updateHeights {
      updateHeight()
    }
  }

  // Clear, reset height
  func clear() {
    // State
    attachmentItems.removeAll()
    sendButton.updateCanSend(false)
    state.clearReplyingToMsgId()

    // Views
    attachments.clearViews()
    textViewContentHeight =
      textEditor
        .getTypingLineHeight() // manually for now, FIXME: make it automatic in texteditor.clear
    textEditor.clear()
    clearAttachments(updateHeights: false)

    // must be last call
    updateHeight()
  }

  // Send the message
  func send() {
    DispatchQueue.main.async(qos: .userInteractive) {
      self.ignoreNextHeightChange = true
      let rawText = self.textEditor.string.trimmingCharacters(in: .whitespacesAndNewlines)
      let replyToMsgId = self.state.replyingToMsgId
      let attachmentItems = self.attachmentItems
      let canSend = !rawText.isEmpty || attachmentItems.count > 0

      // make it nil if empty
      let text = if rawText.isEmpty, !attachmentItems.isEmpty {
        nil as String?
      } else {
        rawText
      }

      if !canSend { return }

      // Clear immediately
      self.clear()

      // Add message
      if attachmentItems.isEmpty {
        // Text-only
        let _ = Transactions.shared.mutate(
          transaction:
          .sendMessage(
            TransactionSendMessage(
              text: text,
              peerId: self.peerId,
              chatId: self.chatId ?? 0, // FIXME: chatId fallback
              mediaItems: [],
              replyToMsgId: replyToMsgId
            )
          )
        )
      } else {
        // With image/file/video
        for (index, (_, attachment)) in attachmentItems.enumerated() {
          let isFirst = index == 0
          let _ = Transactions.shared.mutate(
            transaction:
            .sendMessage(
              TransactionSendMessage(
                text: isFirst ? text : nil,
                peerId: self.peerId,
                chatId: self.chatId ?? 0, // FIXME: chatId fallback
                mediaItems: [attachment],
                replyToMsgId: isFirst ? replyToMsgId : nil
              )
            )
          )
        }
      }

      // Cancel typing
      Task {
        await ComposeActions.shared.stoppedTyping(for: self.peerId)
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        // Scroll to new message
        self.state.scrollToBottom()
      }

      self.ignoreNextHeightChange = false
    }
  }

  func focus() {
    textEditor.focus()
  }

  private var keyMonitorUnsubscribe: (() -> Void)?

  private func setupKeyDownHandler() {
    keyMonitorUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .textInputCatchAll,
      key: "compose\(peerId)",
      handler: { [weak self] event in
        guard let self else { return }

        focus()

        textEditor.textView.insertText(
          event.characters ?? "",
          replacementRange: NSRange(location: NSNotFound, length: 0)
        )
      }
    )
  }

  override func viewDidHide() {
    keyMonitorUnsubscribe?()
    keyMonitorUnsubscribe = nil
  }

  deinit {
    keyMonitorUnsubscribe?()
    keyMonitorUnsubscribe = nil

    Log.shared.debug("🗑️🧹 deinit ComposeAppKit: \(self)")
  }
}

// MARK: External Interface for file drop

extension ComposeAppKit {
  func handleFileDrop(_ urls: [URL]) {
    for url in urls {
      addFile(url)
    }
  }

  func handleImageDropOrPaste(_ image: NSImage) {
    addImage(image)
  }
}

// MARK: Delegate

extension ComposeAppKit: NSTextViewDelegate, ComposeTextViewDelegate {
  // Implement delegate methods as needed
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
    // Send
    send()
    return true // handled
  }

  func textViewDidPressReturn(_ textView: NSTextView) -> Bool {
    // Send
    send()
    return true // handled
  }

  func textView(_ textView: NSTextView, didReceiveImage image: NSImage) {
    handleImageDropOrPaste(image)
  }

  func textView(_ textView: NSTextView, didReceiveFile url: URL) {
    handleFileDrop([url])
  }

  func textView(_ textView: NSTextView, didReceiveVideo url: URL) {
    // TODO:
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    // TODO: This is slow
    if textView.string.isRTL {
      textView.baseWritingDirection = .rightToLeft
    } else {
      textView.baseWritingDirection = .leftToRight
    }

    if !ignoreNextHeightChange {
      updateHeightIfNeeded(for: textView)
    }

    if textView.string.isEmpty {
      // Handle empty text
      textEditor.showPlaceholder(true)
      sendButton.updateCanSend(false)

      // Cancel typing
      Task {
        await ComposeActions.shared.stoppedTyping(for: self.peerId)
      }
    } else {
      // Handle non-empty text
      textEditor.showPlaceholder(false)
      sendButton.updateCanSend(true)

      // Start typing
      Task {
        await ComposeActions.shared.startedTyping(for: self.peerId)
      }
    }
  }

  func calculateContentHeight(for textView: NSTextView) -> CGFloat {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return 0 }

    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height
  }

  func updateHeightIfNeeded(for textView: NSTextView) {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return }

    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height

    if abs(textViewContentHeight - contentHeight) < 8.0 {
      // minimal change to height ignore
      return
    }

    textViewContentHeight = contentHeight

    updateHeight()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    // guard let textView = notification.object as? NSTextView else { return }
    // Handle selection changes if needed
  }
}

// MARK: ComposeMenuButtonDelegate

extension ComposeAppKit: ComposeMenuButtonDelegate {
  func composeMenuButton(_ button: ComposeMenuButton, didSelectImage image: NSImage) {
    handleImageDropOrPaste(image)
  }

  func composeMenuButton(_ button: ComposeMenuButton, didSelectFiles urls: [URL]) {
    handleFileDrop(urls)
  }

  func composeMenuButton(didCaptureImage image: NSImage) {
    handleImageDropOrPaste(image)
  }
}
