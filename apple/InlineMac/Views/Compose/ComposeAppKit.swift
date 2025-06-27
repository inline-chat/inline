import AppKit
import Combine
import GRDB
import InlineKit
import InlineProtocol
import Logger
import SwiftUI
import TextProcessing

class ComposeAppKit: NSView {
  // MARK: - Internals

  private var log = Log.scoped("Compose", enableTracing: true)

  // MARK: - Props

  private var peerId: InlineKit.Peer
  private var chat: InlineKit.Chat?
  private var chatId: Int64? { chat?.id }
  private var dependencies: AppDependencies

  // We load draft from the dialog passed from chat view model
  private var dialog: InlineKit.Dialog?

  // MARK: - State

  weak var messageList: MessageListAppKit?
  weak var parentChatView: ChatViewAppKit?

  var viewModel: MessagesProgressiveViewModel? {
    messageList?.viewModel
  }

  private var isEmpty: Bool {
    textEditor.isAttributedTextEmpty
  }

  private var isEmptyTrimmed: Bool {
    textEditor.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canSend: Bool {
    !isEmptyTrimmed || attachmentItems.count > 0
  }

  // [uniqueId: FileMediaItem]
  private var attachmentItems: [String: FileMediaItem] = [:] {
    didSet {
      updateSendButtonIfNeeded()
    }
  }

  // Mention completion
  private var mentionCompletionMenu: MentionCompletionMenu?
  private var mentionDetector = MentionDetector()
  private var chatParticipantsViewModel: InlineKit.ChatParticipantsWithMembersViewModel?
  private var currentMentionRange: MentionRange?
  private var mentionKeyMonitorEscUnsubscribe: (() -> Void)?
  private var mentionMenuConstraints: [NSLayoutConstraint] = []

  // Draft
  private var draftDebounceTask: Task<Void, Never>?
  private var initializedDraft = false

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

  // Reply/Edit
  private lazy var messageView: ComposeMessageView = {
    let view = ComposeMessageView(
      onClose: { [weak self] in
        self?.state.clearReplyingToMsgId()
        self?.state.clearEditingMsgId()
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

  // TODO: Only use this in pre-Tahoe
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

    // Set up mention menu positioning now that we have a window
    addMentionMenuToSuperview()
  }

  // MARK: Initialization

  init(
    peerId: InlineKit.Peer,
    messageList: MessageListAppKit,
    chat: InlineKit.Chat?,
    dependencies: AppDependencies,
    parentChatView: ChatViewAppKit? = nil,
    dialog: InlineKit.Dialog?
  ) {
    self.peerId = peerId
    self.messageList = messageList
    self.chat = chat
    self.dependencies = dependencies
    self.parentChatView = parentChatView
    self.dialog = dialog

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
    addSubview(messageView)

    addSubview(attachments)

    // to bottom
    addSubview(sendButton)
    addSubview(menuButton)
    addSubview(textEditor)

    setupReplyingView()
    setUpConstraints()
    setupTextEditor()
    setupMentionCompletion()
  }

  /// This method is called from ChatViewAppKit's viewDidLayout
  /// Load draft, set initial height, etc here.
  public func didLayout() {
    guard !initializedDraft else { return }
    let loaded = loadDraft()
    if !loaded {
      updateHeight(animate: false)

      // If no draft is loaded, show placeholder
      textEditor.showPlaceholder(true)
    }
    initializedDraft = true
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
      messageView.leadingAnchor.constraint(equalTo: textEditor.leadingAnchor, constant: textViewHorizontalPadding),
      messageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalOuterSpacing),

      // attachments
      attachments.leadingAnchor.constraint(equalTo: textEditor.leadingAnchor, constant: textViewHorizontalPadding),
      attachments.trailingAnchor.constraint(equalTo: textEditor.trailingAnchor),
      attachments.topAnchor.constraint(equalTo: messageView.bottomAnchor),

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
        updateMessageView(to: replyingToMsgId, kind: .replying, animate: true)
        focus()
      }.store(in: &cancellables)

    state.editingMsgIdPublisher
      .sink { [weak self] editingMsgId in
        guard let self else { return }
        updateMessageView(to: editingMsgId, kind: .editing, animate: true)
        focus()
      }.store(in: &cancellables)
  }

  private func setupTextEditor() {
    // Set the delegate if needed
    textEditor.delegate = self
  }

  // MARK: - Mention Completion

  private func setupMentionCompletion() {
    guard let chatId else {
      return
    }

    // Initialize chat participants view model
    chatParticipantsViewModel = InlineKit.ChatParticipantsWithMembersViewModel(
      db: dependencies.database,
      chatId: chatId
    )

    // Create mention completion menu
    mentionCompletionMenu = MentionCompletionMenu()
    mentionCompletionMenu?.delegate = self
    mentionCompletionMenu?.translatesAutoresizingMaskIntoConstraints = false

    // Subscribe to participants updates
    chatParticipantsViewModel?.$participants
      .sink { [weak self] participants in
        Log.shared.trace("🔍 Participants updated: \(participants.count) participants")
        self?.mentionCompletionMenu?.updateParticipants(participants)
      }
      .store(in: &cancellables)

    // Fetch participants from server
    Task {
      Log.shared.trace("🔍 Fetching chat participants from server...")
      await chatParticipantsViewModel?.refetchParticipants()
    }
  }

  private func addMentionMenuToSuperview() {
    guard let menu = mentionCompletionMenu,
          menu.superview == nil,
          let parentView = parentChatView?.view
    else {
      Log.shared.debug("🔍 addMentionMenuToSuperview: menu already has superview, is nil, or no parent chat view")
      return
    }

    Log.shared.debug("🔍 addMentionMenuToSuperview: adding menu to ChatViewAppKit's view")

    // Add menu to the parent chat view
    parentView.addSubview(menu)

    // Remove any existing constraints
    NSLayoutConstraint.deactivate(mentionMenuConstraints)
    mentionMenuConstraints.removeAll()

    // Create new constraints to position above compose with full width
    mentionMenuConstraints = [
      menu.leadingAnchor.constraint(equalTo: leadingAnchor),
      menu.trailingAnchor.constraint(equalTo: trailingAnchor),
      menu.bottomAnchor.constraint(equalTo: topAnchor),
    ]

    NSLayoutConstraint.activate(mentionMenuConstraints)
    Log.shared.debug("🔍 addMentionMenuToSuperview: menu positioned above compose view")
  }

  private func showMentionCompletion(for query: String) {
    Log.shared.debug("🔍 showMentionCompletion: query='\(query)'")

    // Ensure menu is added to view hierarchy
    addMentionMenuToSuperview()

    mentionCompletionMenu?.filterParticipants(with: query)
    mentionCompletionMenu?.show()

    // Add escape handler for mention menu
    mentionKeyMonitorEscUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_mention_\(peerId)",
      handler: { [weak self] _ in
        self?.hideMentionCompletion()
      }
    )
  }

  private func hideMentionCompletion() {
    Log.shared.debug("🔍 hideMentionCompletion")
    currentMentionRange = nil
    mentionCompletionMenu?.hide()

    // Remove escape handler
    mentionKeyMonitorEscUnsubscribe?()
    mentionKeyMonitorEscUnsubscribe = nil
  }

  private func detectMentionAtCursor() {
    let cursorPosition = textEditor.textView.selectedRange().location
    let attributedText = textEditor.attributedString
    let text = textEditor.plainText

    Log.shared.debug("🔍 detectMentionAtCursor: cursor=\(cursorPosition), text='\(text)'")

    if let mentionRange = mentionDetector.detectMentionAt(cursorPosition: cursorPosition, in: attributedText) {
      currentMentionRange = mentionRange
      Log.shared.debug("🔍 Mention detected: '\(mentionRange.query)' at \(mentionRange.range)")
      showMentionCompletion(for: mentionRange.query)
    } else {
      Log.shared.debug("🔍 No mention detected")
      hideMentionCompletion()
    }
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
    if state.replyingToMsgId != nil || state.editingMsgId != nil {
      height += Theme.embeddedMessageHeight
    }

    // Attachments
    height += attachments.getHeight()

    return height
  }

  func updateHeight(animate: Bool = false) {
    let textEditorHeight = getTextViewHeight()
    let wrapperHeight = getHeight()

    log.trace("updating height wrapper=\(wrapperHeight), textEditor=\(textEditorHeight)")

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

    // Update mention menu position if it's visible
    if mentionCompletionMenu?.isVisible == true {
      updateMentionMenuPosition()
    }
  }

  private func updateMentionMenuPosition() {
    guard let menu = mentionCompletionMenu, menu.superview != nil else { return }

    // Remove existing constraints
    NSLayoutConstraint.deactivate(mentionMenuConstraints)
    mentionMenuConstraints.removeAll()

    // Create new constraints with updated position
    mentionMenuConstraints = [
      menu.leadingAnchor.constraint(equalTo: leadingAnchor),
      menu.trailingAnchor.constraint(equalTo: trailingAnchor),
      menu.bottomAnchor.constraint(equalTo: topAnchor, constant: -8),
    ]

    NSLayoutConstraint.activate(mentionMenuConstraints)
  }

  private var ignoreNextHeightChange = false

  // MARK: - Reply View

  private func setupReplyingView() {
    if let replyingToMsgId = state.replyingToMsgId {
      updateMessageView(to: replyingToMsgId, kind: .replying, animate: false, shouldUpdateHeight: false)
    }

    if let editingMessageId = state.editingMsgId {
      updateMessageView(to: editingMessageId, kind: .editing, animate: false, shouldUpdateHeight: false)
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
        state.clearEditingMsgId()
        removeReplyEscHandler()
      }
    )
  }

  private func removeReplyEscHandler() {
    keyMonitorEscUnsubscribe?()
    keyMonitorEscUnsubscribe = nil
  }

  private func updateMessageView(
    to msgId: Int64?,
    kind: ComposeMessageView.Kind,
    animate: Bool = false,
    shouldUpdateHeight: Bool = true
  ) {
    if let msgId {
      // Update and show the reply view
      if let message = try? FullMessage.get(messageId: msgId, chatId: chatId ?? 0) {
        messageView.update(with: message, kind: kind)
        messageView.open(animated: animate)
        addReplyEscHandler()

        if kind == .editing {
          // set string to the message
          let attributedString = toAttributedString(
            text: message.message.text ?? "",
            entities: message.message.entities
          )

          // set manually without updating height
          textEditor.replaceAttributedString(attributedString)
          textEditor.showPlaceholder(text.isEmpty)
          // calculate text height to prepare for height change
          updateContentHeight(for: textEditor.textView)
        }
      }
    } else {
      // Hide and remove the reply view
      messageView.close(animated: true)
      removeReplyEscHandler()

      if kind == .editing {
        // clear string
        setText("", animate: animate, shouldUpdateHeight: false)
      }
    }

    if shouldUpdateHeight {
      // Update height to accommodate the reply view
      updateHeight(animate: animate)
    }
  }

  // MARK: - Actions

  private func shouldSendAsFile(_ image: NSImage) -> Bool {
    // Too narrow
    let ratio = max(image.size.width / image.size.height, image.size.height / image.size.width)
    if ratio > 20 {
      return true
    }

    // Too small
    if image.size.width < 50, image.size.height < 50 {
      return true
    }

    return false
  }

  func addImage(_ image: NSImage, _ url: URL? = nil) {
    // Format
    let preferredImageFormat: ImageFormat? = if let url {
      url.pathExtension.lowercased() == "png" ? ImageFormat.png : ImageFormat.jpeg
    } else { nil }

    // Check aspect ratio
    if shouldSendAsFile(image) {
      let tempDir = FileHelpers.getTrueTemporaryDirectory()
      let result = try? image.save(
        to: tempDir,
        withName: url?.pathComponents.last ?? "image\(preferredImageFormat?.toExt() ?? ".jpg")",
        format: preferredImageFormat ?? .jpeg
      )
      if let (_, url) = result {
        addFile(url)
      }
      return
    }

    do {
      // Save

      let photoInfo = try FileCache.savePhoto(image: image, preferredFormat: preferredImageFormat)
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
    state.clearEditingMsgId()
    clearDraft()

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
      let attributedString = self.textEditor.attributedString
      let replyToMsgId = self.state.replyingToMsgId
      let attachmentItems = self.attachmentItems
      // keep a copy of editingMessageId before we clear it
      let editingMessageId = self.state.editingMsgId

      // Extract mention entities from attributed text
      // TODO: replace with `fromAttributedString`
      let (rawText, entities) = ProcessEntities.fromAttributedString(attributedString)

      // make it nil if empty
      let text = if rawText.isEmpty, !attachmentItems.isEmpty {
        nil as String?
      } else {
        rawText
      }

      if !self.canSend { return }

      // Edit message
      if let editingMessageId {
        // Edit message
        Transactions.shared.mutate(transaction: .editMessage(.init(
          messageId: editingMessageId,
          text: text ?? "",
          chatId: self.chatId ?? 0,
          peerId: self.peerId,
          entities: entities
        )))
      }

      // Send message
      else if attachmentItems.isEmpty {
        // Text-only
        let _ = Transactions.shared.mutate(
          transaction:
          .sendMessage(
            TransactionSendMessage(
              text: text,
              peerId: self.peerId,
              chatId: self.chatId ?? 0, // FIXME: chatId fallback
              mediaItems: [],
              replyToMsgId: replyToMsgId,
              isSticker: nil,
              entities: entities
            )
          )
        )
      }

      // With image/file/video
      else {
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
                replyToMsgId: isFirst ? replyToMsgId : nil,
                isSticker: nil,
                entities: isFirst ? entities : nil
              )
            )
          )
        }
      }

      // Clear immediately
      self.clear()

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

  // TODO: Abstract setAttributedString out of this
  func setText(_ text: String, animate: Bool = false, shouldUpdateHeight: Bool = true) {
    let attributedString = textEditor.createAttributedString(text)
    textEditor.replaceAttributedString(attributedString)
    updateContentHeight(for: textEditor.textView)
    if shouldUpdateHeight {
      updateHeight(animate: animate)
    }
    // reevaluate placeholder
    textEditor.showPlaceholder(text.isEmpty)
  }

  private var keyMonitorUnsubscribe: (() -> Void)?
  private var keyMonitorPasteUnsubscribe: (() -> Void)?

  private func setupKeyDownHandler() {
    keyMonitorUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .textInputCatchAll,
      key: "compose\(peerId)",
      handler: { [weak self] event in
        guard let self else { return }

        // Only allow valid printable characters, not control/navigation keys
        guard let characters = event.characters,
              characters != " ", // Ignore space as it prevents our image preview from working
              !characters.isEmpty,
              characters.allSatisfy({ char in
                // Check if character is printable (not a control character)
                if let scalar = char.unicodeScalars.first {
                  return scalar.properties.isAlphabetic || scalar.properties.isMath
                }
                return false
              })
        else { return }

        // Put cursor in the text field
        focus()

        // Insert text
        textEditor.textView.insertText(
          characters,
          replacementRange: NSRange(location: NSNotFound, length: 0)
        )
      }
    )

    // Add paste handler
    keyMonitorPasteUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .paste,
      key: "compose_paste_\(peerId)",
      handler: { [weak self] _ in
        self?.handleGlobalPaste()
      }
    )
  }

  private func handleGlobalPaste() {
    let pasteboard = NSPasteboard.general

    // Use the existing pasteboard handling from the text view
    let handled = textEditor.textView.handleAttachments(from: pasteboard)

    if handled {
      focus()
    }
  }

  deinit {
    saveDraft()

    draftDebounceTask?.cancel()
    draftDebounceTask = nil

    // Clean up
    keyMonitorUnsubscribe?()
    keyMonitorUnsubscribe = nil
    keyMonitorPasteUnsubscribe?()
    keyMonitorPasteUnsubscribe = nil

    // Clean up mention resources
    mentionKeyMonitorEscUnsubscribe?()
    mentionKeyMonitorEscUnsubscribe = nil
    NSLayoutConstraint.deactivate(mentionMenuConstraints)
    mentionMenuConstraints.removeAll()
    mentionCompletionMenu?.removeFromSuperview()

    log.trace("deinit")
  }
}

// MARK: External Interface for file drop

extension ComposeAppKit {
  func handleFileDrop(_ urls: [URL]) {
    for url in urls {
      addFile(url)
    }
  }

  func handleTextDropOrPaste(_ text: String) {
    textEditor.insertText(text)
  }

  func handleImageDropOrPaste(_ image: NSImage, _ url: URL? = nil) {
    addImage(image, url)
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

  func textViewDidPressArrowUp(_ textView: NSTextView) -> Bool {
    // If mention menu is visible, let it handle the arrow key
    if mentionCompletionMenu?.isVisible == true {
      mentionCompletionMenu?.selectPrevious()
      return true
    }

    // only if empty
    guard textView.string.count == 0 else { return false }

    // fetch last message of ours in this chat that isn't sending or failed
    let lastMsgId = try? dependencies.database.reader.read { db in
      let lastMsg = try InlineKit.Message
        .filter { $0.chatId == chatId }
        .filter { $0.out == true }
        .filter { $0.status == MessageSendingStatus.sent }
        .order { $0.date.desc }
        .limit(1)
        .fetchOne(db)
      return lastMsg?.messageId
    }
    guard let lastMsgId else { return false }

    // Trigger edit mode for last message
    state.setEditingMsgId(lastMsgId)
    return true // handled
  }

  func textViewDidPressReturn(_ textView: NSTextView) -> Bool {
    // If mention menu is visible, select current item with Enter
    if let mentionCompletionMenu, mentionCompletionMenu.isVisible {
      if mentionCompletionMenu.selectCurrentItem() {
        return true
      }
    }

    // Send
    send()
    return true
  }

  func textView(_ textView: NSTextView, didReceiveImage image: NSImage, url: URL? = nil) {
    handleImageDropOrPaste(image, url)
  }

  func textView(_ textView: NSTextView, didReceiveFile url: URL) {
    handleFileDrop([url])
  }

  func textView(_ textView: NSTextView, didReceiveVideo url: URL) {
    // TODO: Handle video
    handleFileDrop([url])
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    // Prevent mention style leakage to new text
    textView.updateTypingAttributesIfNeeded()

    if !ignoreNextHeightChange {
      updateHeightIfNeeded(for: textView)
    } else {
      log.trace("ignore next height change")
    }

    // Detect mentions
    detectMentionAtCursor()

    if textEditor.isAttributedTextEmpty {
      // Handle empty text
      textEditor.showPlaceholder(true)

      // Cancel typing
      Task {
        await ComposeActions.shared.stoppedTyping(for: self.peerId)
      }
    } else {
      // Handle non-empty text
      textEditor.showPlaceholder(false)

      // Start typing
      Task {
        await ComposeActions.shared.startedTyping(for: self.peerId)
      }
    }

    updateSendButtonIfNeeded()
    saveDraftWithDebounce()
  }

  /// Reflect state changes in send button
  func updateSendButtonIfNeeded() {
    sendButton.updateCanSend(canSend)
  }

  func calculateContentHeight(for textView: NSTextView) -> CGFloat {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return 0 }

    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).height
  }

  func updateContentHeight(for textView: NSTextView) {
    textViewContentHeight = calculateContentHeight(for: textView)
  }

  func updateHeightIfNeeded(for textView: NSTextView, animate: Bool = false) {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return }

    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height

    if abs(textViewContentHeight - contentHeight) < 8.0 {
      // minimal change to height ignore
      log.trace("minimal change to height ignore")
      return
    }

    log.trace("update height to \(contentHeight)")

    textViewContentHeight = contentHeight

    updateHeight(animate: animate)
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    // Reset typing attributes when cursor moves to prevent mention style leakage
    textView.updateTypingAttributesIfNeeded()
  }

  func textViewDidPressArrowDown(_ textView: NSTextView) -> Bool {
    // If mention menu is visible, let it handle the arrow key
    if mentionCompletionMenu?.isVisible == true {
      mentionCompletionMenu?.selectNext()
      return true
    }

    return false // not handled
  }

  func textViewDidPressTab(_ textView: NSTextView) -> Bool {
    // If mention menu is visible, select current item
    if mentionCompletionMenu?.isVisible == true {
      mentionCompletionMenu?.selectCurrentItem()
      return true
    }

    return false // not handled
  }

  func textViewDidPressEscape(_ textView: NSTextView) -> Bool {
    // If mention menu is visible, hide it
    if mentionCompletionMenu?.isVisible == true {
      hideMentionCompletion()
      return true
    }

    return false // not handled
  }

  func textView(_ textView: NSTextView, didDetectMentionWith query: String, at location: Int) {
    // This method is called from text change detection
    // Implementation will be in textDidChange
  }

  func textViewDidCancelMention(_ textView: NSTextView) {
    hideMentionCompletion()
  }

  func textViewDidGainFocus(_ textView: NSTextView) {
    // TODO: Show mentions menu if needed
  }

  func textViewDidLoseFocus(_ textView: NSTextView) {
    // Hide mention menu when text view loses focus
    hideMentionCompletion()
  }
}

// MARK: ComposeMenuButtonDelegate

extension ComposeAppKit: ComposeMenuButtonDelegate {
  func composeMenuButton(_ button: ComposeMenuButton, didSelectImage image: NSImage, url: URL) {
    handleImageDropOrPaste(image, url)
  }

  func composeMenuButton(_ button: ComposeMenuButton, didSelectFiles urls: [URL]) {
    handleFileDrop(urls)
  }

  func composeMenuButton(didCaptureImage image: NSImage) {
    handleImageDropOrPaste(image)
  }
}

// MARK: MentionCompletionMenuDelegate

extension ComposeAppKit: MentionCompletionMenuDelegate {
  func mentionMenu(_ menu: MentionCompletionMenu, didSelectUser user: UserInfo, withText text: String, userId: Int64) {
    guard let mentionRange = currentMentionRange else { return }
    log.trace("mentionMenu didSelectUser: \(text), \(userId)")

    let currentAttributedText = textEditor.attributedString
    let result = mentionDetector.replaceMention(
      in: currentAttributedText,
      range: mentionRange.range,
      with: text,
      userId: userId
    )

    // Update attributed text and cursor position
    ignoreNextHeightChange = true
    textEditor.setAttributedString(result.newAttributedText)
    textEditor.textView.setSelectedRange(NSRange(location: result.newCursorPosition, length: 0))
    ignoreNextHeightChange = false

    // Hide the menu
    hideMentionCompletion()

    // Update height if needed
    updateHeightIfNeeded(for: textEditor.textView)
  }

  func mentionMenuDidRequestClose(_ menu: MentionCompletionMenu) {
    hideMentionCompletion()
  }
}

// MARK: - Rich text loading

extension ComposeAppKit {
  func toAttributedString(text: String, entities: MessageEntities?) -> NSAttributedString {
    let attributedString = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: ComposeTextEditor.font,
        textColor: ComposeTextEditor.textColor,
        linkColor: ComposeTextEditor.linkColor,
        convertMentionsToLink: false
      )
    )

    return attributedString
  }

  func setMessage(text: String, entities: MessageEntities?) {
    // Convert to attributed string
    let attributedString = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: ComposeTextEditor.font,
        textColor: ComposeTextEditor.textColor,
        linkColor: ComposeTextEditor.linkColor,
        convertMentionsToLink: false
      )
    )

    setAttributedString(attributedString)
  }

  func setAttributedString(_ attributedString: NSAttributedString) {
    // Set as compose text
    textEditor.replaceAttributedString(attributedString)
    textEditor.showPlaceholder(text.isEmpty)

    // Measure new height
    updateContentHeight(for: textEditor.textView)

    // Update compose height
    updateHeight(animate: false)
  }
}

// MARK: - Draft

extension ComposeAppKit {
  /// Loads draft and if nothing found returns false
  func loadDraft() -> Bool {
    // We should have the dialog, in the edge case we don't, just ignore draft for now
    guard let dialog else { return false }

    // Check if there is a draft message
    guard let draft = dialog.draftMessage else { return false }

    // Convert to attributed string
    let attributedString = toAttributedString(
      text: draft.text,
      entities: draft.entities,
    )

    // Layout for accurate height measurements. Without this, it doesn't use the
    // correct width for text height calculations
    layoutSubtreeIfNeeded()

    // Set as compose text
    setAttributedString(attributedString)

    return true
  }

  private func saveDraft() {
    Drafts.shared.update(peerId: peerId, attributedString: textEditor.attributedString)
  }

  private func clearDraft() {
    Drafts.shared.clear(peerId: peerId)
  }

  /// Triggers save with a 300ms delay which cancels previous Task thus creating a basic debounced
  /// version to be used on textDidChange.
  private func saveDraftWithDebounce() {
    draftDebounceTask?.cancel()
    draftDebounceTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300), tolerance: .milliseconds(100))
      guard !Task.isCancelled else { return }
      self?.saveDraft()
    }
  }
}
