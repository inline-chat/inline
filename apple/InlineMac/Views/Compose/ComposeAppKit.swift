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
    !isEmptyTrimmed || attachmentItems.count > 0 || state.forwardContext != nil
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
  private var isHandlingStickerInsertion = false
  private let stickerDetector = ComposeStickerDetector()
  private let rightButtonSpacing: CGFloat = 6

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
      },
      onSendWithoutNotification: { [weak self] in
        self?.send(sendMode: .modeSilent)
      }
    )
    return view
  }()

  private lazy var emojiButton: ComposeEmojiButton = {
    let view = ComposeEmojiButton()
    view.delegate = self
    view.translatesAutoresizingMaskIntoConstraints = false
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
        self?.state.clearForwarding()
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
    addSubview(emojiButton)
    addSubview(menuButton)
    addSubview(textEditor)

    setupReplyingView()
    setUpConstraints()
    setupTextEditor()
    setupMentionCompletion()
  }

  /// This method is called from ChatViewAppKit's viewDidLayout
  /// Load draft, set initial height, etc here.
  func didLayout() {
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
    let attachmentsHorizontalInset = horizontalOuterSpacing + Theme.composeButtonSize + textViewHorizontalPadding
    attachments.setHorizontalContentInset(attachmentsHorizontalInset)

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

      // emoji
      emojiButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -rightButtonSpacing),
      emojiButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsBottomSpacing),

      // menu
      menuButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalOuterSpacing),
      menuButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsBottomSpacing),

      // reply (height handled internally)
      messageView.leadingAnchor.constraint(equalTo: textEditor.leadingAnchor, constant: textViewHorizontalPadding),
      messageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalOuterSpacing),

      // attachments
      attachments.leadingAnchor.constraint(equalTo: leadingAnchor),
      attachments.trailingAnchor.constraint(equalTo: trailingAnchor),
      attachments.topAnchor.constraint(equalTo: messageView.bottomAnchor),

      // text editor
      textEditor.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor),
      textEditor.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor),
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

    state.forwardContextPublisher
      .sink { [weak self] forwardContext in
        guard let self else { return }
        let messageId = forwardContext?.messageIds.first
        let sourceChatId = forwardContext?.sourceChatId
        updateMessageView(
          to: messageId,
          sourceChatId: sourceChatId,
          kind: .forwarding,
          animate: true
        )
        updateSendButtonIfNeeded()
        focus()
      }.store(in: &cancellables)
  }

  private func setupTextEditor() {
    // Set the delegate if needed
    textEditor.delegate = self

    // Configure text input settings
    textEditor.textView.isAutomaticSpellingCorrectionEnabled = AppSettings.shared.automaticSpellCorrection
    textEditor.textView.isContinuousSpellCheckingEnabled = AppSettings.shared.checkSpellingWhileTyping

    // Listen to AppSettings changes
    AppSettings.shared.$automaticSpellCorrection
      .sink { [weak self] enabled in
        self?.textEditor.textView.isAutomaticSpellingCorrectionEnabled = enabled
      }.store(in: &cancellables)

    AppSettings.shared.$checkSpellingWhileTyping
      .sink { [weak self] enabled in
        self?.textEditor.textView.isContinuousSpellCheckingEnabled = enabled
      }.store(in: &cancellables)
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
    currentMentionRange = nil
    mentionCompletionMenu?.hide()

    // Remove escape handler
    mentionKeyMonitorEscUnsubscribe?()
    mentionKeyMonitorEscUnsubscribe = nil
  }

  private func detectMentionAtCursor() {
    let cursorPosition = textEditor.textView.selectedRange().location
    let attributedText = textEditor.attributedString
    log.trace("detectMentionAtCursor cursor=\(cursorPosition)")

    if let mentionRange = mentionDetector.detectMentionAt(cursorPosition: cursorPosition, in: attributedText) {
      currentMentionRange = mentionRange
      showMentionCompletion(for: mentionRange.query)
    } else {
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
    if state.replyingToMsgId != nil || state.editingMsgId != nil || state.forwardContext != nil {
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

    if let forwardContext = state.forwardContext,
       let previewMessageId = forwardContext.messageIds.first
    {
      updateMessageView(
        to: previewMessageId,
        sourceChatId: forwardContext.sourceChatId,
        kind: .forwarding,
        animate: false,
        shouldUpdateHeight: false
      )
    }

    updateSendButtonIfNeeded()
  }

  private var keyMonitorEscUnsubscribe: (() -> Void)?
  private func addReplyEscHandler() {
    keyMonitorEscUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_reply_\(peerId)",
      handler: { [weak self] _ in
        guard let self else { return }
        state.clearReplyingToMsgId()
        state.clearEditingMsgId()
        state.clearForwarding()
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
    sourceChatId: Int64? = nil,
    kind: ComposeMessageView.Kind,
    animate: Bool = false,
    shouldUpdateHeight: Bool = true
  ) {
    if let msgId {
      // Update and show the reply view
      let resolvedChatId = sourceChatId ?? chatId ?? 0
      if let message = try? FullMessage.get(messageId: msgId, chatId: resolvedChatId) {
        messageView.update(with: message, kind: kind)
        messageView.open(animated: animate)
        addReplyEscHandler()

        if kind == .editing {
          // set string to the message
          let attributedString = toAttributedString(
            text: message.message.text ?? "",
            entities: message.message.entities
          )

          // TODO: Extract these to a function
          // set manually without updating height
          textEditor.replaceAttributedString(attributedString)
          textEditor.showPlaceholder(text.isEmpty)
          sendButton.updateCanSend(canSend)
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

    // Add a placeholder view immediately, then persist to cache/DB off the main thread.
    let pendingId = "pending_photo_\(UUID().uuidString)"
    attachments.addImageView(image, id: pendingId)
    updateHeight(animate: true)

    let task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      if Task.isCancelled { return }
      do {
        let photoInfo = try FileCache.savePhoto(image: image, preferredFormat: preferredImageFormat)
        let mediaItem = FileMediaItem.photo(photoInfo)
        let uniqueId = mediaItem.getItemUniqueId()

        await MainActor.run { [weak self] in
          guard let self else { return }
          guard self.pendingImageSaveTasks[pendingId] != nil else { return } // removed/cancelled
          self.pendingImageSaveTasks.removeValue(forKey: pendingId)

          // Swap the placeholder with the persisted attachment id.
          self.attachments.removeImageView(id: pendingId)
          self.attachments.addImageView(image, id: uniqueId)
          self.attachmentItems[uniqueId] = mediaItem
          self.updateHeight(animate: true)
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self else { return }
          guard self.pendingImageSaveTasks[pendingId] != nil else { return } // removed/cancelled
          self.pendingImageSaveTasks.removeValue(forKey: pendingId)
          self.attachments.removeImageView(id: pendingId)
          self.updateHeight(animate: true)
        }
        Log.shared.error("Failed to save photo in attachments", error: error)
      }
    }

    pendingImageSaveTasks[pendingId] = task
  }

  func removeImage(_ id: String) {
    if let task = pendingImageSaveTasks.removeValue(forKey: id) {
      task.cancel()
    }

    // Update UI
    attachments.removeImageView(id: id)
    updateHeight(animate: true)

    // Update state
    attachmentItems.removeValue(forKey: id)
  }

  private func isVideoFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
  }

  private func loadThumbnail(from photoInfo: PhotoInfo?) -> NSImage? {
    guard let localPath = photoInfo?.sizes.first?.localPath else { return nil }
    let url = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(localPath)
    return NSImage(contentsOf: url)
  }

  @MainActor
  func addVideo(_ url: URL, thumbnail: NSImage? = nil) async {
    do {
      let videoInfo = try await FileCache.saveVideo(url: url, thumbnail: thumbnail)
      let mediaItem = FileMediaItem.video(videoInfo)
      let uniqueId = mediaItem.getItemUniqueId()

      attachments.addVideoView(videoInfo, id: uniqueId)
      // Only swap the view if we just generated a new thumbnail
      if let previousItem = attachmentItems[uniqueId],
         case let FileMediaItem.video(prevVideoInfo) = previousItem,
         prevVideoInfo.thumbnail == nil,
         videoInfo.thumbnail != nil {
        attachments.removeVideoView(id: uniqueId)
        attachments.addVideoView(videoInfo, id: uniqueId)
      }

      attachmentItems[uniqueId] = mediaItem
      updateHeight(animate: true)
    } catch {
      Log.shared.error("Failed to save video in attachments", error: error)
    }
  }

  func removeVideo(_ id: String) {
    attachments.removeVideoView(id: id)
    attachmentItems.removeValue(forKey: id)
    updateHeight(animate: true)
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
    state.clearForwarding()
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
  func send(sendMode: MessageSendMode? = nil) {
    // DispatchQueue.main.async(qos: .userInteractive) {
    ignoreNextHeightChange = true
    let attributedString = trimmedAttributedString(textEditor.attributedString)
    let replyToMsgId = state.replyingToMsgId
    let attachmentItemsSnapshot = attachmentItems
    // keep a copy of editingMessageId before we clear it
    let editingMessageId = state.editingMsgId
    let forwardContext = state.forwardContext

    // Extract mention entities from attributed text
    // TODO: replace with `fromAttributedString`
    let (rawText, entities) = ProcessEntities.fromAttributedString(attributedString)

    let hasText = !rawText.isEmpty
    let hasAttachments = !attachmentItemsSnapshot.isEmpty

    // make it nil if empty
    let text = if rawText.isEmpty, hasAttachments {
      nil as String?
    } else {
      rawText
    }

    func enqueueAttachments(replyToMessageId: Int64?) {
      for (index, (_, attachment)) in attachmentItemsSnapshot.enumerated() {
        let isFirst = index == 0
        _ = Transactions.shared.mutate(
          transaction:
          .sendMessage(
            TransactionSendMessage(
              text: isFirst ? text : nil,
              peerId: peerId,
              chatId: chatId ?? 0, // FIXME: chatId fallback
              mediaItems: [attachment],
              replyToMsgId: isFirst ? replyToMessageId : nil,
              isSticker: nil,
              entities: isFirst ? entities : nil,
              sendMode: sendMode
            )
          )
        )
      }
    }

    if !canSend { return }

    // Edit message
    if let editingMessageId {
      // Edit message
      Task.detached(priority: .userInitiated) { // @MainActor in
        try await Api.realtime.send(.editMessage(
          messageId: editingMessageId,
          text: text ?? "",
          chatId: self.chatId ?? 0,
          peerId: self.peerId,
          entities: entities
        ))
      }
    }

    // Forward message
    else if let forwardContext {
      guard !forwardContext.messageIds.isEmpty else {
        log.error("Forward failed: empty message ids")
        return
      }

      if hasAttachments {
        enqueueAttachments(replyToMessageId: nil)
      }

      Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }

        if hasText, !hasAttachments {
          _ = await Api.realtime.sendQueued(
            .sendMessage(
              text: text,
              peerId: self.peerId,
              chatId: self.chatId ?? 0, // FIXME: chatId fallback
              replyToMsgId: nil,
              isSticker: nil,
              entities: entities,
              sendMode: sendMode
            )
          )
        }

        do {
          let result = try await Api.realtime.send(.forwardMessages(
            fromPeerId: forwardContext.fromPeerId,
            toPeerId: self.peerId,
            messageIds: forwardContext.messageIds
          ))

          if case let .forwardMessages(response) = result, response.updates.isEmpty {
            _ = await Api.realtime.sendQueued(.getChatHistory(peer: self.peerId))
          }
        } catch {
          self.log.error("Forward failed", error: error)
        }
      }
      state.clearForwarding()
    }

    // Send message
    else if attachmentItemsSnapshot.isEmpty {
      // Text-only
      // Send via V2
      Task.detached(priority: .userInitiated) { // @MainActor in
        try await Api.realtime.send(
          .sendMessage(
            text: text,
            peerId: self.peerId,
            chatId: self.chatId ?? 0, // FIXME: chatId fallback
            replyToMsgId: replyToMsgId,
            isSticker: nil,
            entities: entities,
            sendMode: sendMode
          )
        )
      }
      // let _ = Transactions.shared.mutate(
      //   transaction:
      //   .sendMessage(
      //     TransactionSendMessage(
      //       text: text,
      //       peerId: self.peerId,
      //       chatId: self.chatId ?? 0, // FIXME: chatId fallback
      //       mediaItems: [],
      //       replyToMsgId: replyToMsgId,
      //       isSticker: nil,
      //       entities: entities
      //     )
      //   )
      // )
    }

    // With image/file/video
    else {
      enqueueAttachments(replyToMessageId: replyToMsgId)
    }

    // Clear immediately
    clear()

    // Cancel typing
    Task {
      await ComposeActions.shared.stoppedTyping(for: self.peerId)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      // Scroll to new message
      self.state.scrollToBottom()
    }

    ignoreNextHeightChange = false
    // }
  }

  private func trimmedAttributedString(_ attributedString: NSAttributedString) -> NSAttributedString {
    let whitespaceSet = CharacterSet.whitespacesAndNewlines
    let fullString = attributedString.string as NSString
    let startRange = fullString.rangeOfCharacter(from: whitespaceSet.inverted)
    if startRange.location == NSNotFound {
      return NSAttributedString()
    }
    let endRange = fullString.rangeOfCharacter(from: whitespaceSet.inverted, options: .backwards)
    let trimmedRange = NSRange(
      location: startRange.location,
      length: NSMaxRange(endRange) - startRange.location
    )
    return attributedString.attributedSubstring(from: trimmedRange)
  }

  func sendSticker(_ image: NSImage) {
    let replyToMsgId = state.replyingToMsgId

    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let photoInfo = try FileCache.savePhoto(image: image, optimize: true)
        let mediaItem = FileMediaItem.photo(photoInfo)

        Transactions.shared.mutate(
          transaction: .sendMessage(
            TransactionSendMessage(
              text: nil,
              peerId: self.peerId,
              chatId: self.chatId ?? 0,
              mediaItems: [mediaItem],
              replyToMsgId: replyToMsgId,
              isSticker: true,
              entities: nil
            )
          )
        )
      } catch {
        self.log.error("Failed to send sticker", error: error)
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.state.scrollToBottom()
    }
  }

  func focus() {
    textEditor.focus()
  }

  private func focusWindowIfNeeded() {
    guard let window else { return }
    if !NSApplication.shared.isActive {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
    }
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
    sendButton.updateCanSend(canSend)
  }

  private var keyMonitorUnsubscribe: (() -> Void)?
  private var keyMonitorPasteUnsubscribe: (() -> Void)?
  private var pendingImageSaveTasks: [String: Task<Void, Never>] = [:]

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

    // If this is non-text content, route through attachments.
    if textEditor.textView.handleAttachments(from: pasteboard, includeText: false) {
      focus()
      return
    }

    // Otherwise, perform a native plain-text paste (ComposeNSTextView disables rich paste for reliability).
    focus()
    textEditor.textView.paste(nil)
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
  func handlePasteboardAttachments(_ attachments: [PasteboardAttachment]) {
    for attachment in attachments {
      switch attachment {
        case let .image(image, url):
          handleImageDropOrPaste(image, url)
        case let .video(url, thumbnail):
          Task { [weak self] in
            await self?.addVideo(url, thumbnail: thumbnail)
          }
        case let .file(url, _):
          handleFileDrop([url])
        case let .text(text):
          handleTextDropOrPaste(text)
      }
    }
  }

  func handleFileDrop(_ urls: [URL]) {
    for url in urls {
      if isVideoFile(url) {
        Task { [weak self] in await self?.addVideo(url) }
      } else {
        addFile(url)
      }
    }
  }

  func handleTextDropOrPaste(_ text: String) {
    textEditor.insertText(text)
    focusWindowIfNeeded()
    focus()
  }

  func handleImageDropOrPaste(_ image: NSImage, _ url: URL? = nil) {
    addImage(image, url)
    focusWindowIfNeeded()
    focus()
  }
}

// MARK: Delegate

extension ComposeAppKit: NSTextViewDelegate, ComposeTextViewDelegate {
  // Implement delegate methods as needed
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
    // Always send with command enter
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

    if !AppSettings.shared.sendsWithCmdEnter {
      // Send
      send()
      return true
    }

    return false // not handled
  }

  func textView(_ textView: NSTextView, didReceiveImage image: NSImage, url: URL? = nil) {
    handleImageDropOrPaste(image, url)
  }

  func textView(_ textView: NSTextView, didReceiveFile url: URL) {
    handleFileDrop([url])
  }

  func textView(_ textView: NSTextView, didReceiveVideo url: URL) {
    Task { [weak self] in await self?.addVideo(url) }
  }

  func textView(_ textView: NSTextView, didFailToPasteAttachment failure: PasteboardAttachmentFailure) {
    if failure.isTelegramSource {
      ToastCenter.shared.showError("Telegram copies images as private files. Drag the image or use Save Media.")
      return
    }

    if failure.isSymlink {
      ToastCenter.shared.showError("That clipboard file is a private symlink and can't be read.")
      return
    }

    ToastCenter.shared.showError("Couldn't read the file from the clipboard.")
  }

  /// Note(@mo): User reported Chinese users still see the placeholder when they start typing in Chinese characters.
  /// So apparently there is a feature in macOS for these languages called Chinese IME (Input Method Editor) which lays
  /// out text temporarily without committing it. This method can detect this and hide the placeholder. And show it back
  /// when that text is removed.
  func textView(
    _ textView: NSTextView,
    shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    // Hide placeholder during IME composition and handle undo to empty text
    let currentText = textView.string
    let replacementText = replacementString ?? ""

    // Calculate resulting text safely
    let nsString = currentText as NSString
    guard affectedCharRange.location <= nsString.length,
          NSMaxRange(affectedCharRange) <= nsString.length
    else {
      return true
    }

    let resultingText = nsString.replacingCharacters(in: affectedCharRange, with: replacementText)
    textEditor.showPlaceholder(resultingText.isEmpty)

    return true
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

    handleStickerDetectionIfNeeded(for: textView)

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

  private func handleStickerDetectionIfNeeded(for textView: NSTextView) {
    guard #available(macOS 15.0, *) else { return }
    guard isHandlingStickerInsertion == false else { return }

    let stickers = stickerDetector.detectStickers(in: textView.attributedString())
    guard stickers.isEmpty == false else { return }
    guard let textStorage = textView.textStorage else { return }

    isHandlingStickerInsertion = true
    let fullString = textStorage.string as NSString
    let sorted = stickers.sorted { $0.range.location > $1.range.location }
    for sticker in sorted {
      sendSticker(sticker.image)
      let range = sticker.range
      guard range.location != NSNotFound, NSMaxRange(range) <= textStorage.length else { continue }
      let composedRange = fullString.rangeOfComposedCharacterSequences(for: range)
      let safeRange = NSMaxRange(composedRange) <= textStorage.length ? composedRange : range
      textStorage.replaceCharacters(in: safeRange, with: "")
    }
    textView.resetTypingAttributesToDefault()
    isHandlingStickerInsertion = false

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

// MARK: ComposeEmojiButtonDelegate

extension ComposeAppKit: ComposeEmojiButtonDelegate {
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveText text: String) {
    focus()
    textEditor.insertText(text)
  }

  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveSticker image: NSImage) {
    sendSticker(image)
    focus()
  }
}

// MARK: ComposeMenuButtonDelegate

extension ComposeAppKit: ComposeMenuButtonDelegate {
  func composeMenuButton(_ button: ComposeMenuButton, didSelectImage image: NSImage, url: URL) {
    handleImageDropOrPaste(image, url)
  }

  func composeMenuButton(_ button: ComposeMenuButton, didSelectVideo url: URL) {
    Task { [weak self] in await self?.addVideo(url) }
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
