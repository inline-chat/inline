import AppKit
import Combine
import GRDB
import InlineKit
import InlineMacUI
import InlineProtocol
import Logger
import SwiftUI
import TextProcessing

enum GlassComposeCompletionMenuPlacement {
  case above
  case below
}

class GlassComposeAppKit: NSView {
  private static let attachmentMarker = "\u{FFFC}"

  // MARK: - Internals

  private var log = Log.scoped("Compose", enableTracing: false)

  // MARK: - Props

  private let usage: ComposeUsage
  private let layout: GlassComposeLayout
  private let capabilities: ComposeCapabilities
  private let completionMenuPlacement: GlassComposeCompletionMenuPlacement
  private let chatPeerID: InlineKit.Peer?
  private var peerId: InlineKit.Peer {
    guard let chatPeerID else {
      preconditionFailure("Chat-only peer state was accessed by new-thread Compose")
    }
    return chatPeerID
  }

  private var chat: InlineKit.Chat?
  private var peerUser: InlineKit.User?
  private var chatId: Int64? {
    chat?.id
  }

  private var dependencies: AppDependencies
  private let mentionedParticipants: MentionedParticipantsAutoAddManager

  /// We load draft from the dialog passed from chat view model
  private var dialog: InlineKit.Dialog?

  // MARK: - State

  weak var messageList: (any ChatMessageListController)?
  weak var parentChatView: ChatViewAppKit?

  var viewModel: MessagesProgressiveViewModel? {
    messageList?.viewModel
  }

  private var overlayHostView: NSView? {
    switch usage {
      case .chat:
        parentChatView?.view
      case let .newThread(context):
        context.overlayHostView()
    }
  }

  private var composeSessionKey: String {
    switch usage {
      // Preserve every existing chat key exactly. The new namespace only
      // exists for a composer that has no peer to identify it.
      case .chat: "\(peerId)"
      case let .newThread(context): "new_thread_\(context.sessionID.uuidString)"
    }
  }

  private var textInputMonitorKey: String {
    switch usage {
      case .chat: "compose\(peerId)"
      case .newThread: "compose_\(composeSessionKey)"
    }
  }

  private var isEmpty: Bool {
    textEditor.isAttributedTextEmpty
  }

  private var isEmptyTrimmed: Bool {
    textEditor.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasAnyAttachments: Bool {
    switch usage {
      case .chat:
        !attachmentItems.isEmpty
      case let .newThread(context):
        !context.attachmentStore.attachments.isEmpty || context.attachmentStore.hasPendingAttachments
    }
  }

  private var canSend: Bool {
    switch usage {
      case .chat:
        !drafts2.hasPendingAttachments(peer: peerId) &&
          (!isEmptyTrimmed || attachmentItems.count > 0 || state.forwardContext != nil)
      case let .newThread(context):
        !context.attachmentStore.hasPendingAttachments &&
          (!isEmptyTrimmed || !context.attachmentStore.attachments.isEmpty) &&
          !isSubmittingNewThread
    }
  }

  private var canMutateDraft: Bool {
    if case .newThread = usage {
      return !isSubmittingNewThread
    }
    return true
  }

  private var canStartVoiceRecording: Bool {
    guard capabilities.supportsVoiceMessages, case .chat = usage else { return false }
    return isVoiceRecordingAvailable(isVoiceActive: voiceViewModel.isActive)
  }

  private var currentVoiceActive: Bool {
    guard capabilities.supportsVoiceMessages else { return false }
    return switch usage {
      case .chat: voiceViewModel.isActive
      case .newThread: false
    }
  }

  private var placeholderText: String {
    if case .newThread = usage {
      return "New thread"
    }

    if chat?.isReplyThread == true {
      return "Reply"
    }

    guard let peerUser,
          peerId.asUserId() == peerUser.id,
          !peerUser.isCurrentUser(),
          let firstName = peerUser.firstName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !firstName.isEmpty
    else {
      return "Message"
    }

    return "Message \(firstName)"
  }

  private var placeholderSymbolName: String? {
    switch usage {
      case .chat:
        nil
      case let .newThread(context):
        context.placeholderSymbolName
    }
  }

  private func isVoiceRecordingAvailable(isVoiceActive: Bool) -> Bool {
    guard capabilities.supportsVoiceMessages, case .chat = usage else { return false }
    return !isVoiceActive &&
      !drafts2.hasPendingAttachments(peer: peerId) &&
      (ComposeVoiceInputMode.selected == .transcribe || (isEmptyTrimmed && attachmentItems.isEmpty)) &&
      state.editingMsgId == nil &&
      state.forwardContext == nil
  }

  private lazy var voiceViewModel = ComposeVoiceRecordingViewModel(peerId: peerId)
  private var voiceEscapeKeyUnsubscribe: (() -> Void)?
  private var voiceReturnKeyUnsubscribe: (() -> Void)?
  private var voiceSpaceKeyUnsubscribe: (() -> Void)?

  // [uniqueId: FileMediaItem]
  private var attachmentItems: [String: FileMediaItem] = [:] {
    didSet {
      updateSendButtonIfNeeded()
      notifyNewThreadDraftChanged()
    }
  }

  // Mention completion
  private var mentionCompletionMenu: MentionCompletionMenu?
  private var mentionDetector = MentionDetector()
  private var chatParticipantsViewModel: InlineKit.ChatParticipantsWithMembersViewModel?
  private var currentMentionRange: MentionRange?
  private var mentionKeyMonitorEscUnsubscribe: (() -> Void)?
  private var mentionMenuConstraints: [NSLayoutConstraint] = []
  private var didRequestMentionParticipants = false
  private var mentionParticipantsTask: Task<Void, Never>?
  private var mentionAgentsTask: Task<Void, Never>?
  private var mentionCandidates = MentionCompletionCandidates.empty
  private var mentionAgents: [MentionableBotAgent] = []

  // Slash command completion
  private var commandCompletionMenu: CommandCompletionMenu?
  private let slashCommandDetector = SlashCommandDetector()
  private var peerBotCommandsViewModel: PeerBotCommandsViewModel?
  private var currentSlashCommandRange: SlashCommandRange?
  private var currentSlashQuery: String?
  private var commandKeyMonitorEscUnsubscribe: (() -> Void)?
  private var commandMenuConstraints: [NSLayoutConstraint] = []
  private var inlineCommandTask: Task<Void, Never>?

  // Shared autocomplete
  private let threadLinkDetector = ThreadLinkDetector()
  private let emojiAutocompleteDetector = EmojiAutocompleteDetector()
  private lazy var autocompleteViewModel: ComposeAutocompleteViewModel = switch usage {
    case .chat:
    .init(
      db: dependencies.database,
      peer: peerId,
      spaceId: chat?.spaceId,
      limit: 24,
      recentThreadChatIds: { [weak self] limit in
        self?.recentThreadChatIds(limit: limit) ?? []
      },
      emojiItems: { query, limit in
        ComposeEmojiAutocompleteProvider.items(matching: query, limit: limit)
      },
      externalResourceItems: { [weak self] query, limit in
        guard let self else { return [] }
        return try await ExternalResourceSearchClient.search(
          peer: peerId,
          query: query,
          limit: limit
        )
      }
    )
    case .newThread:
    .init(
      db: dependencies.database,
      limit: 24,
      emojiItems: { query, limit in
        ComposeEmojiAutocompleteProvider.items(matching: query, limit: limit)
      },
      externalResourceItems: { query, limit in
        try await ExternalResourceSearchClient.search(peer: nil, query: query, limit: limit)
      }
    )
  }

  private var autocompleteMenu: ComposeAutocompleteMenu?
  private var autocompleteMenuConstraints: [NSLayoutConstraint] = []
  private var autocompleteKeyMonitorEscUnsubscribe: (() -> Void)?
  private var newThreadScrollObserver: NSObjectProtocol?

  private func recentThreadChatIds(limit: Int) -> [Int64] {
    var ids: [Int64] = []
    var seen = Set<Int64>()

    func append(_ peer: InlineKit.Peer?) {
      guard ids.count < limit,
            let chatId = peer?.asThreadId(),
            seen.insert(chatId).inserted
      else {
        return
      }
      ids.append(chatId)
    }

    if let nav3 = dependencies.nav3, nav3.historyIndex >= 0 {
      let count = min(nav3.historyIndex + 1, nav3.history.count)
      for state in nav3.history.prefix(count).reversed() {
        append(state.route.selectedPeer)
      }
    }

    if let nav2 = dependencies.nav2 {
      for entry in nav2.history.reversed() {
        append(entry.route.selectedPeer)
      }
    }

    for entry in dependencies.nav.history.reversed() {
      append(entry.route.selectedPeer)
    }

    return ids
  }

  // Draft
  private let drafts2 = Drafts2.shared
  private var initializedDraft = false
  private var didRequestFinalDraftPersistence = false
  private var isCancellingTranscriptionForRemoval = false
  private var draftEntitySaveTask: Task<Void, Never>?
  private var draftAttachmentObserverCancel: (@Sendable () -> Void)?
  private var isSubmittingNewThread = false

  // Internal
  private var heightConstraint: NSLayoutConstraint!
  private var textHeightConstraint: NSLayoutConstraint!
  private let controlMode: ComposeControlMode = .glass
  private var minHeight: CGFloat {
    controlMode.glassControlsMinHeight + layout.viewportBottomInset
  }

  private var radius: CGFloat {
    round(controlMode.textMinHeight / 2)
  }

  private var horizontalOuterSpacing: CGFloat {
    layout.viewportHorizontalInset
  }

  private var viewportBottomInset: CGFloat {
    layout.viewportBottomInset
  }

  // ---
  private var textViewContentHeight: CGFloat = 0.0
  private var textViewHeight: CGFloat = 0.0
  private var lastMeasuredTextLayoutWidth: CGFloat = 0.0

  // Features
  private var feature_animateHeightChanges = false // for now until fixing how to update list view smoothly
  private var isHandlingStickerInsertion = false
  private lazy var paragraphDirectionController = ComposeParagraphDirectionController(textView: textEditor.textView)
  private let stickerDetector = ComposeStickerDetector()
  private let rightButtonSpacing: CGFloat = 6
  private var silentModeButtonWidthConstraint: NSLayoutConstraint?
  private var silentModeToSendConstraint: NSLayoutConstraint?
  private var silentModeToEdgeConstraint: NSLayoutConstraint?
  private var glassTextTrailingConstraint: NSLayoutConstraint?
  private var glassAttachmentWidthConstraint: NSLayoutConstraint?
  private var glassTrailingWidthConstraint: NSLayoutConstraint?
  private var glassAttachmentToPillConstraint: NSLayoutConstraint?
  private var glassPillToTrailingConstraint: NSLayoutConstraint?

  // MARK: Views

  private lazy var textEditor: ComposeTextEditor = {
    // Glass divergence: use normal input-style text insets instead of the
    // legacy compose's single-line recentering inside a taller text field.
    let textEditor = ComposeTextEditor(initiallySingleLine: true, mode: controlMode)
    textEditor.placeholderText = placeholderText
    textEditor.placeholderSymbolName = placeholderSymbolName
    textEditor.translatesAutoresizingMaskIntoConstraints = false
    return textEditor
  }()

  private lazy var sendButton: ComposeSendButton = .init(
    frame: .zero,
    mode: controlMode,
    presentation: layout == .accessoryBar ? .accessoryBar : .standard,
    allowsSendSilently: capabilities.menu.contains(.sendSilently),
    onSend: { [weak self] in
      self?.send()
    },
    onToggleSendSilently: { [weak self] in
      guard let self, case .chat = usage else { return }
      state.toggleSendSilently()
    }
  )

  private lazy var silentModeButton: ComposeSilentModeButton = {
    let view = ComposeSilentModeButton(
      mode: controlMode,
      presentation: layout == .accessoryBar ? .accessoryBar : .standard
    )
    view.onClick = { [weak self] in
      guard let self, canMutateDraft else { return }
      switch usage {
        case .chat:
          state.setSendSilently(false)
        case let .newThread(context):
          context.setSendSilently(!context.sendSilently())
          updateSilentModeUI(animated: false)
      }
    }
    view.isHidden = true
    return view
  }()

  private lazy var voiceButton: ComposeVoiceButton = {
    let view = ComposeVoiceButton(mode: controlMode)
    view.onClick = { [weak self] in
      self?.startVoiceRecording()
    }
    view.onModeChanged = { [weak self] in self?.updateVoiceAvailability() }
    view.isHidden = true
    return view
  }()

  private lazy var voiceInputView: NSHostingView<ComposeVoiceInputView> = {
    let view = NSHostingView(rootView: ComposeVoiceInputView(
      viewModel: voiceViewModel,
      mode: controlMode,
      onPause: { [weak self] in
        self?.pauseVoiceRecording()
      },
      onPlay: { [weak self] in
        self?.toggleVoicePlayback()
      },
      onCancel: { [weak self] in
        self?.cancelVoiceRecording()
      },
      onSend: { [weak self] in
        self?.sendVoiceRecording()
      }
    ))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
  }()

  private lazy var emojiButton: ComposeEmojiButton = {
    let view = ComposeEmojiButton(mode: controlMode)
    view.delegate = self
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var menuButton: ComposeMenuButton = {
    let view = ComposeMenuButton(
      mode: controlMode,
      capabilities: capabilities.menu,
      presentation: layout == .accessoryBar ? .accessoryBar : .standard
    )
    view.delegate = self
    view.isNewThreadEnabledProvider = { [weak self] in
      guard let self else { return false }
      return commandLaunchState().isEnabled && chatId != nil && inlineCommandTask == nil
    }
    view.onNewThread = { [weak self] in
      guard let self, commandLaunchState().isEnabled, chatId != nil else { return }
      performInlineCommand(.createSubthread, fromMenu: true)
    }
    view.isCommandsEnabledProvider = { [weak self] in
      self?.commandLaunchState().isEnabled == true
    }
    view.onToggleSendSilently = { [weak self] in
      guard let self, case .chat = usage else { return }
      state.toggleSendSilently()
    }
    view.isSendSilentlyEnabledProvider = { [weak self] in
      guard let self, case .chat = usage else { return false }
      return state.sendSilently
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// Reply/Edit
  private lazy var messageView: ComposeMessageView = {
    let view = ComposeMessageView(
      onClose: { [weak self] in
        guard let self, case .chat = usage else { return }
        state.clearReplyingToMsgId()
        state.clearEditingMsgId()
        state.clearForwarding()
      }
    )

    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// Add attachments view
  private lazy var attachments: ComposeAttachments = {
    let view = ComposeAttachments(frame: .zero, compose: self)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var glassContainerView: NSView?
  private var glassContentView: NSView?
  private var glassAttachmentView: NSView?
  private var glassComposePillView: NSView?
  private var glassComposePillContentView: NSView?
  private var glassEditorRowView: NSView?
  private var glassTrailingView: NSView?
  private var glassAccessoryBarView: NSView?
  private var glassAccessoryHeightConstraint: NSLayoutConstraint?
  private var glassSupplementaryToControlsConstraint: NSLayoutConstraint?
  private var glassSupplementaryToEdgeConstraint: NSLayoutConstraint?
  private var isAccessoryBarExpanded = false
  private var newThreadEscapeKeyUnsubscribe: (() -> Void)?

  // -------

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    guard window != nil else {
      removeNewThreadScrollObserver()
      return
    }
    if case .chat = usage {
      hydrateInitialDraftIfNeeded()

      // Refresh state skipped while a previous host was being removed.
      updateVoiceAvailability(phase: voiceViewModel.phase)
      updateVoiceKeyHandlers(phase: voiceViewModel.phase)
      updateHeight(animate: false, voicePhase: voiceViewModel.phase)

      DispatchQueue.main.async { [weak self] in
        self?.focus()
      }
    } else {
      updateHeight(animate: false)
      textEditor.showPlaceholder(isEmpty)
    }

    if mentionCompletionMenu != nil {
      addMentionMenuToSuperview()
    }

    if commandCompletionMenu != nil {
      addCommandMenuToSuperview()
    }

    installNewThreadScrollObserverIfNeeded()
  }

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    if case .chat = usage {
      if newSuperview == nil {
        cancelTranscriptionForRemoval()
        requestImmediateDraftPersistenceIfNeeded()
      } else {
        didRequestFinalDraftPersistence = false
      }
    }
    super.viewWillMove(toSuperview: newSuperview)
  }

  private func cancelTranscriptionForRemoval() {
    guard voiceViewModel.inputMode == .transcribe, voiceViewModel.isActive else { return }
    // cancel() publishes phase synchronously. AppKit may already be finalizing
    // the host's sibling views, so the phase sink must not relayout this tree.
    isCancellingTranscriptionForRemoval = true
    defer { isCancellingTranscriptionForRemoval = false }
    voiceViewModel.cancel()
  }

  // MARK: Initialization

  init(
    peerId: InlineKit.Peer,
    messageList: any ChatMessageListController,
    chat: InlineKit.Chat?,
    peerUser: InlineKit.User?,
    dependencies: AppDependencies,
    toolbarState: ChatToolbarState? = nil,
    parentChatView: ChatViewAppKit? = nil,
    dialog: InlineKit.Dialog?,
    layout: GlassComposeLayout = .sideControls,
    capabilities: ComposeCapabilities = .chatDefault
  ) {
    usage = .chat
    self.layout = layout
    self.capabilities = capabilities
    completionMenuPlacement = .above
    chatPeerID = peerId
    self.messageList = messageList
    self.chat = chat
    self.peerUser = peerUser
    self.dependencies = dependencies
    self.mentionedParticipants = MentionedParticipantsAutoAddManager(
      dependencies: dependencies,
      toolbarState: toolbarState
    )
    self.parentChatView = parentChatView
    self.dialog = dialog

    super.init(frame: .zero)
    textEditor.textView.smartLinkPeer = peerId
    textEditor.textView.smartLinkEscapeAvailabilityDidChange = { [weak self] available in
      self?.setSmartLinkEscapeHandlerEnabled(available)
    }
    draftAttachmentObserverCancel = drafts2.observeAttachmentResults(peer: peerId) { [weak self] result in
      self?.handleDraftAttachmentResult(result)
    }
    setupView()
    setupObservers()
    setupKeyDownHandler()
    restorePendingDraftAttachmentPlaceholders()
  }

  init(
    newThread context: NewThreadComposeContext,
    dependencies: AppDependencies,
    layout: GlassComposeLayout = .accessoryBar,
    capabilities: ComposeCapabilities = .allChatsNewThread,
    completionMenuPlacement: GlassComposeCompletionMenuPlacement
  ) {
    usage = .newThread(context)
    self.layout = layout
    self.capabilities = capabilities
    self.completionMenuPlacement = completionMenuPlacement
    chatPeerID = nil
    chat = nil
    peerUser = nil
    self.dependencies = dependencies
    mentionedParticipants = MentionedParticipantsAutoAddManager(
      dependencies: dependencies,
      toolbarState: nil
    )
    dialog = nil

    super.init(frame: .zero)
    textEditor.textView.smartLinkEscapeAvailabilityDidChange = { [weak self] available in
      self?.setSmartLinkEscapeHandlerEnabled(available)
    }
    setupView()
    setupObservers()
    setupKeyDownHandler()
  }

  func setPeerUser(_ user: InlineKit.User?) {
    guard peerUser != user else { return }
    peerUser = user
    textEditor.placeholderText = placeholderText
    textEditor.placeholderSymbolName = placeholderSymbolName
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Setup

  func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    setupGlassChromeViews()

    if case .chat = usage {
      setupReplyingView()
    }
    setUpConstraints()
    updateSilentModeUI(animated: false, forceLayout: false)
    updateVoiceAvailability()
    setupTextEditor()
  }

  private func setupGlassChromeViews() {
    guard #available(macOS 26.0, *) else { return }

    let containerView = NSGlassEffectContainerView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.spacing = controlMode.glassSpacing

    let contentView = NSView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    embed(contentView, in: containerView)

    addSubview(containerView)

    let composePillView = makeGlassEffectView(cornerRadius: radius)
    let pillContentView = NSView()
    pillContentView.translatesAutoresizingMaskIntoConstraints = false
    let editorRowView = NSView()
    editorRowView.translatesAutoresizingMaskIntoConstraints = false

    embed(pillContentView, in: composePillView)

    contentView.addSubview(composePillView)

    if case .chat = usage {
      pillContentView.addSubview(messageView)
    }
    pillContentView.addSubview(attachments)
    pillContentView.addSubview(editorRowView)

    editorRowView.addSubview(textEditor)

    switch layout {
      case .sideControls:
        contentView.addSubview(menuButton, positioned: .below, relativeTo: composePillView)
        if capabilities.supportsVoiceMessages {
          contentView.addSubview(voiceButton)
        }

        if capabilities.showsEmojiButton {
          editorRowView.addSubview(emojiButton)
        }
        editorRowView.addSubview(sendButton)
        editorRowView.addSubview(silentModeButton)
        if capabilities.supportsVoiceMessages, case .chat = usage {
          editorRowView.addSubview(voiceInputView)
        }

        glassAttachmentView = menuButton
        glassTrailingView = capabilities.supportsVoiceMessages ? voiceButton : nil

      case .accessoryBar:
        let accessoryBarView = NSView()
        accessoryBarView.translatesAutoresizingMaskIntoConstraints = false
        accessoryBarView.alphaValue = 0
        accessoryBarView.isHidden = true
        pillContentView.addSubview(accessoryBarView)
        accessoryBarView.addSubview(menuButton)

        if case let .newThread(context) = usage {
          let supplementaryView = context.supplementaryAccessoryView
          supplementaryView.translatesAutoresizingMaskIntoConstraints = false
          supplementaryView.setContentHuggingPriority(.defaultLow, for: .horizontal)
          accessoryBarView.addSubview(supplementaryView)
        }
        if capabilities.showsSilentModeToggle {
          accessoryBarView.addSubview(silentModeButton)
        }
        accessoryBarView.addSubview(sendButton)
        glassAccessoryBarView = accessoryBarView
    }

    glassContainerView = containerView
    glassContentView = contentView
    glassComposePillView = composePillView
    glassComposePillContentView = pillContentView
    glassEditorRowView = editorRowView
  }

  @available(macOS 26.0, *)
  private func makeGlassEffectView(cornerRadius: CGFloat) -> NSGlassEffectView {
    let view = NSGlassEffectView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.cornerRadius = cornerRadius
    view.style = .regular
    if #available(macOS 27.0, *) {
      view.effectIsInteractive = true
    }
    return view
  }

  @available(macOS 26.0, *)
  private func embed(_ contentView: NSView, in glassView: NSGlassEffectView) {
    contentView.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView = contentView
    pinEmbeddedContentView(contentView, fallbackSuperview: glassView)
  }

  @available(macOS 26.0, *)
  private func embed(_ contentView: NSView, in containerView: NSGlassEffectContainerView) {
    contentView.translatesAutoresizingMaskIntoConstraints = false
    containerView.contentView = contentView
    pinEmbeddedContentView(contentView, fallbackSuperview: containerView)
  }

  private func pinEmbeddedContentView(_ contentView: NSView, fallbackSuperview: NSView) {
    if contentView.superview == nil {
      fallbackSuperview.addSubview(contentView)
    }

    guard let superview = contentView.superview else { return }
    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: superview.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: superview.bottomAnchor),
    ])
  }

  func prepareForMessageSelection() -> Bool {
    guard !currentVoiceActive else {
      ToastCenter.shared.showError("Finish your voice message before selecting messages.")
      return false
    }
    hideMentionCompletion()
    hideCommandCompletion()
    hideAutocomplete()
    return true
  }

  /// This method is called from ChatViewAppKit's viewDidLayout.
  /// Draft hydration happens on window attachment so layout stays measurement-only.
  func didLayout() {
    updateHeightForTextLayoutWidthChange()
    if mentionCompletionMenu?.isVisible == true {
      updateMentionMenuPosition()
    }
  }

  private func hydrateInitialDraftIfNeeded() {
    guard !initializedDraft else { return }
    let loaded = loadDraft()
    if !loaded {
      updateHeight(animate: false)
      textEditor.showPlaceholder(true)
    }
    initializedDraft = true
  }

  private func setUpConstraints() {
    heightConstraint = heightAnchor.constraint(equalToConstant: minHeight)
    textHeightConstraint = textEditor.heightAnchor.constraint(equalToConstant: textEditor.minHeight)

    let textViewHorizontalPadding = textEditor.horizontalPadding
    attachments.setHorizontalContentInset(textViewHorizontalPadding)

    silentModeButtonWidthConstraint = silentModeButton.widthAnchor.constraint(equalToConstant: 0)
    silentModeToSendConstraint = silentModeButton.trailingAnchor.constraint(
      equalTo: sendButton.leadingAnchor,
      constant: 0
    )

    guard let glassContainerView,
          let glassContentView,
          let glassComposePillView,
          let glassComposePillContentView,
          let glassEditorRowView
    else {
      return
    }

    var constraints: [NSLayoutConstraint] = [
      heightConstraint,

      glassContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalOuterSpacing),
      glassContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalOuterSpacing),
      glassContainerView.topAnchor.constraint(equalTo: topAnchor),
      glassContainerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -viewportBottomInset),

      glassComposePillView.topAnchor.constraint(equalTo: glassContentView.topAnchor),
      glassComposePillView.bottomAnchor.constraint(equalTo: glassContentView.bottomAnchor),

      // attachments
      attachments.leadingAnchor.constraint(equalTo: glassComposePillContentView.leadingAnchor),
      attachments.trailingAnchor.constraint(equalTo: glassComposePillContentView.trailingAnchor),

      glassEditorRowView.leadingAnchor.constraint(equalTo: glassComposePillContentView.leadingAnchor),
      glassEditorRowView.trailingAnchor.constraint(equalTo: glassComposePillContentView.trailingAnchor),
      glassEditorRowView.topAnchor.constraint(equalTo: attachments.bottomAnchor),
      glassEditorRowView.heightAnchor.constraint(greaterThanOrEqualToConstant: controlMode.glassControlsMinHeight),

      textEditor.leadingAnchor.constraint(equalTo: glassEditorRowView.leadingAnchor),
      textHeightConstraint,
      textEditor.centerYAnchor.constraint(equalTo: glassEditorRowView.centerYAnchor),
    ]

    switch usage {
      case .chat:
        constraints.append(contentsOf: [
          messageView.leadingAnchor.constraint(
            equalTo: glassComposePillContentView.leadingAnchor,
            constant: textViewHorizontalPadding
          ),
          messageView.trailingAnchor.constraint(
            equalTo: glassComposePillContentView.trailingAnchor,
            constant: -textViewHorizontalPadding
          ),
          messageView.topAnchor.constraint(equalTo: glassComposePillContentView.topAnchor),
          attachments.topAnchor.constraint(equalTo: messageView.bottomAnchor),
        ])
      case .newThread:
        constraints.append(
          attachments.topAnchor.constraint(equalTo: glassComposePillContentView.topAnchor)
        )
    }

    switch layout {
      case .sideControls:
        guard let glassAttachmentView else { return }

        glassAttachmentWidthConstraint = glassAttachmentView.widthAnchor
          .constraint(equalToConstant: controlMode.sideButtonSize)
        glassAttachmentToPillConstraint = glassComposePillView.leadingAnchor.constraint(
          equalTo: glassAttachmentView.trailingAnchor,
          constant: controlMode.glassSpacing
        )
        glassTextTrailingConstraint = textEditor.trailingAnchor.constraint(
          equalTo: glassEditorRowView.trailingAnchor,
          constant: -glassTrailingControlsReservedWidth(isVoiceActive: false)
        )

        constraints.append(contentsOf: [
          glassAttachmentView.leadingAnchor.constraint(equalTo: glassContentView.leadingAnchor),
          glassAttachmentView.bottomAnchor.constraint(equalTo: glassComposePillView.bottomAnchor),
          glassAttachmentWidthConstraint!,
          glassAttachmentView.heightAnchor.constraint(equalToConstant: controlMode.sideButtonSize),
          glassAttachmentToPillConstraint!,
          glassEditorRowView.bottomAnchor.constraint(equalTo: glassComposePillContentView.bottomAnchor),
          glassTextTrailingConstraint!,
          sendButton.trailingAnchor.constraint(
            equalTo: glassEditorRowView.trailingAnchor,
            constant: -controlMode.sendButtonEdgeInset
          ),
          sendButton.bottomAnchor.constraint(
            equalTo: glassEditorRowView.bottomAnchor,
            constant: -controlMode.sendButtonEdgeInset
          ),
          silentModeButton.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
          silentModeButtonWidthConstraint!,
          silentModeButton.heightAnchor.constraint(equalToConstant: controlMode.silentButtonSize),
          silentModeToSendConstraint!,
        ])

        if capabilities.showsEmojiButton {
          constraints.append(contentsOf: [
            emojiButton.trailingAnchor.constraint(
              equalTo: glassEditorRowView.trailingAnchor,
              constant: -controlMode.pillContentInset
            ),
            emojiButton.bottomAnchor.constraint(
              equalTo: glassEditorRowView.bottomAnchor,
              constant: -controlMode.inlineButtonBottomInset
            ),
          ])
        }

        if let glassTrailingView {
          glassTrailingWidthConstraint = glassTrailingView.widthAnchor
            .constraint(equalToConstant: controlMode.sideButtonSize)
          glassPillToTrailingConstraint = glassTrailingView.leadingAnchor.constraint(
            equalTo: glassComposePillView.trailingAnchor,
            constant: controlMode.glassSpacing
          )
          constraints.append(contentsOf: [
            glassPillToTrailingConstraint!,
            glassTrailingView.trailingAnchor.constraint(equalTo: glassContentView.trailingAnchor),
            glassTrailingView.bottomAnchor.constraint(equalTo: glassComposePillView.bottomAnchor),
            glassTrailingWidthConstraint!,
            glassTrailingView.heightAnchor.constraint(equalToConstant: controlMode.sideButtonSize),
          ])
        } else {
          constraints.append(
            glassComposePillView.trailingAnchor.constraint(equalTo: glassContentView.trailingAnchor)
          )
        }

        if capabilities.supportsVoiceMessages, case .chat = usage {
          constraints.append(contentsOf: [
            voiceInputView.leadingAnchor.constraint(equalTo: glassEditorRowView.leadingAnchor),
            voiceInputView.trailingAnchor.constraint(equalTo: glassEditorRowView.trailingAnchor),
            voiceInputView.topAnchor.constraint(equalTo: glassEditorRowView.topAnchor),
            voiceInputView.bottomAnchor.constraint(equalTo: glassEditorRowView.bottomAnchor),
          ])
        }

      case .accessoryBar:
        guard let glassAccessoryBarView else { return }
        glassAccessoryHeightConstraint = glassAccessoryBarView.heightAnchor.constraint(equalToConstant: 0)
        constraints.append(contentsOf: [
          glassComposePillView.leadingAnchor.constraint(equalTo: glassContentView.leadingAnchor),
          glassComposePillView.trailingAnchor.constraint(equalTo: glassContentView.trailingAnchor),
          glassEditorRowView.bottomAnchor.constraint(equalTo: glassAccessoryBarView.topAnchor),
          textEditor.trailingAnchor.constraint(equalTo: glassEditorRowView.trailingAnchor),
          glassAccessoryBarView.leadingAnchor.constraint(equalTo: glassComposePillContentView.leadingAnchor),
          glassAccessoryBarView.trailingAnchor.constraint(equalTo: glassComposePillContentView.trailingAnchor),
          glassAccessoryBarView.bottomAnchor.constraint(equalTo: glassComposePillContentView.bottomAnchor),
          glassAccessoryHeightConstraint!,
          menuButton.leadingAnchor.constraint(equalTo: glassAccessoryBarView.leadingAnchor, constant: 6),
          menuButton.centerYAnchor.constraint(equalTo: glassAccessoryBarView.centerYAnchor),
          sendButton.trailingAnchor.constraint(equalTo: glassAccessoryBarView.trailingAnchor, constant: -6),
          sendButton.centerYAnchor.constraint(equalTo: glassAccessoryBarView.centerYAnchor),
        ])

        if capabilities.showsSilentModeToggle {
          silentModeButtonWidthConstraint?.constant = controlMode.silentButtonSize
          silentModeToSendConstraint?.constant = -rightButtonSpacing
          silentModeToEdgeConstraint = silentModeButton.trailingAnchor.constraint(
            equalTo: glassAccessoryBarView.trailingAnchor,
            constant: -6
          )
          constraints.append(contentsOf: [
            silentModeButton.centerYAnchor.constraint(equalTo: glassAccessoryBarView.centerYAnchor),
            silentModeButtonWidthConstraint!,
            silentModeButton.heightAnchor.constraint(equalToConstant: controlMode.silentButtonSize),
            silentModeToSendConstraint!,
          ])
        }

        if case let .newThread(context) = usage {
          let supplementaryView = context.supplementaryAccessoryView
          let trailingControl = capabilities.showsSilentModeToggle ? silentModeButton.leadingAnchor : sendButton.leadingAnchor
          glassSupplementaryToControlsConstraint = supplementaryView.trailingAnchor.constraint(
            equalTo: trailingControl,
            constant: -6
          )
          glassSupplementaryToEdgeConstraint = supplementaryView.trailingAnchor.constraint(
            equalTo: glassAccessoryBarView.trailingAnchor,
            constant: -6
          )
          constraints.append(contentsOf: [
            supplementaryView.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor, constant: 6),
            glassSupplementaryToControlsConstraint!,
            supplementaryView.topAnchor.constraint(equalTo: glassAccessoryBarView.topAnchor),
            supplementaryView.bottomAnchor.constraint(equalTo: glassAccessoryBarView.bottomAnchor),
          ])
        }
    }

    NSLayoutConstraint.activate(constraints)
  }

  private var cancellables: Set<AnyCancellable> = []
  private var state: ChatState {
    ChatsManager.get(for: peerId, chatId: chatId ?? 0)
  }

  func setupObservers() {
    if case .chat = usage {
      setupChatObservers()
    }

    Publishers.CombineLatest4(
      autocompleteViewModel.$items,
      autocompleteViewModel.$selectedIndex,
      autocompleteViewModel.$match,
      autocompleteViewModel.$loadState
    )
    .sink { [weak self] items, selectedIndex, match, loadState in
      Task { @MainActor [weak self] in
        guard let self,
              items == autocompleteViewModel.items,
              selectedIndex == autocompleteViewModel.selectedIndex,
              match == autocompleteViewModel.match,
              loadState == autocompleteViewModel.loadState
        else {
          return
        }

        renderAutocompleteMenu(
          items: items,
          selectedIndex: selectedIndex,
          match: match,
          loadState: loadState
        )
      }
    }
    .store(in: &cancellables)
  }

  private func setupChatObservers() {
    state.replyingToMsgIdPublisher
      .sink { [weak self] replyingToMsgId in
        guard let self else { return }
        updateMessageView(to: replyingToMsgId, kind: .replying, animate: true)
        updateVoiceAvailability()
        focus()
      }.store(in: &cancellables)

    state.editingMsgIdPublisher
      .sink { [weak self] editingMsgId in
        guard let self else { return }
        if editingMsgId != nil, voiceViewModel.inputMode == .transcribe { voiceViewModel.cancel() }
        updateMessageView(to: editingMsgId, kind: .editing, animate: true)
        updateVoiceAvailability()
        focus()
      }.store(in: &cancellables)

    state.forwardContextPublisher
      .sink { [weak self] forwardContext in
        guard let self else { return }
        if forwardContext != nil, voiceViewModel.inputMode == .transcribe { voiceViewModel.cancel() }
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

    state.sendSilentlyPublisher
      .sink { [weak self] isEnabled in
        self?.updateSilentModeUI()
        ToastCenter.shared.showInfo(
          isEnabled ? "Send silently enabled" : "Send silently disabled"
        )
      }.store(in: &cancellables)

    if capabilities.supportsVoiceMessages {
      voiceViewModel.$phase
        .sink { [weak self] phase in
          guard let self else { return }
          // Keyboard handlers must be removed even when presentation is suppressed.
          updateVoiceKeyHandlers(phase: phase)
          guard !isCancellingTranscriptionForRemoval else { return }
          updateVoiceAvailability(phase: phase)
          updateHeight(animate: true, voicePhase: phase)
        }
        .store(in: &cancellables)
    }
  }

  private func updateSilentModeUI(
    animated: Bool = true,
    forceLayout: Bool = true,
    isVoiceActive: Bool? = nil
  ) {
    if case let .newThread(context) = usage {
      guard capabilities.showsSilentModeToggle else { return }
      let isEnabled = context.sendSilently()
      sendButton.updateSendSilently(isEnabled)
      silentModeButton.updateSendSilently(isEnabled)
      // The accessory bar owns collapsed visibility. Keep the toggle available
      // even before the draft has content and Send becomes visible.
      silentModeButton.isHidden = false
      return
    }
    let isEnabled = state.sendSilently
    let voiceActive = isVoiceActive ?? currentVoiceActive
    let shouldShow = isEnabled && !voiceActive && canSend
    sendButton.updateSendSilently(isEnabled)
    silentModeButton.isHidden = !shouldShow
    silentModeButtonWidthConstraint?.constant = shouldShow ? controlMode.silentButtonSize : 0
    silentModeToSendConstraint?.constant = shouldShow ? -rightButtonSpacing : 0
    updateGlassEditorTrailingSpace(isVoiceActive: voiceActive)

    guard animated else {
      if forceLayout {
        layoutSubtreeIfNeeded()
      }
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      self.layoutSubtreeIfNeeded()
    }
  }

  private func glassTrailingControlsReservedWidth(isVoiceActive: Bool? = nil) -> CGFloat {
    guard layout == .sideControls else { return 0 }
    let voiceActive = isVoiceActive ?? currentVoiceActive
    guard !voiceActive else { return controlMode.pillContentInset }

    let showsSend = canSend
    let showsEmoji = capabilities.showsEmojiButton && !showsSend
    let buttonWidth = showsSend
      ? controlMode.sendButtonSize
      : (showsEmoji ? controlMode.emojiButtonSize : 0)
    let trailingInset = showsSend ? controlMode.sendButtonEdgeInset : controlMode.pillContentInset
    var width = trailingInset + buttonWidth + rightButtonSpacing

    let sendsSilently = if case .chat = usage {
      state.sendSilently
    } else {
      false
    }
    if showsSend, sendsSilently {
      width += controlMode.silentButtonSize + rightButtonSpacing
    }

    return width
  }

  private func updateGlassEditorTrailingSpace(isVoiceActive: Bool? = nil) {
    glassTextTrailingConstraint?.constant = -glassTrailingControlsReservedWidth(isVoiceActive: isVoiceActive)
  }

  private func updateGlassSideButtonsHidden(_ hidden: Bool) {
    guard layout == .sideControls else { return }
    glassAttachmentView?.isHidden = hidden
    glassAttachmentWidthConstraint?.constant = hidden ? 0 : controlMode.sideButtonSize
    glassAttachmentToPillConstraint?.constant = hidden ? 0 : controlMode.glassSpacing
    updateGlassTrailingButtonHidden(hidden)
  }

  private func updateGlassTrailingButtonHidden(_ hidden: Bool) {
    guard layout == .sideControls else { return }
    glassTrailingView?.isHidden = hidden
    glassTrailingWidthConstraint?.constant = hidden ? 0 : controlMode.sideButtonSize
    glassPillToTrailingConstraint?.constant = hidden ? 0 : controlMode.glassSpacing
  }

  private func updateVoiceAvailability(phase: ComposeVoiceRecordingPhase? = nil) {
    if layout == .accessoryBar {
      let showsSend = canSend
      sendButton.isHidden = !showsSend
      if capabilities.showsSilentModeToggle {
        if showsSend {
          silentModeToEdgeConstraint?.isActive = false
          silentModeToSendConstraint?.isActive = true
        } else {
          silentModeToSendConstraint?.isActive = false
          silentModeToEdgeConstraint?.isActive = true
        }
      } else if showsSend {
        glassSupplementaryToEdgeConstraint?.isActive = false
        glassSupplementaryToControlsConstraint?.isActive = true
      } else {
        glassSupplementaryToControlsConstraint?.isActive = false
        glassSupplementaryToEdgeConstraint?.isActive = true
      }
      updateSilentModeUI(animated: false, forceLayout: false)
      return
    }

    if !capabilities.supportsVoiceMessages {
      if capabilities.showsEmojiButton {
        emojiButton.isHidden = canSend
      }
      sendButton.isHidden = !canSend
      silentModeButton.isHidden = true
      updateGlassTrailingButtonHidden(true)
      updateGlassEditorTrailingSpace(isVoiceActive: false)
      return
    }

    let isVoiceActive = phase.map { $0 != .idle } ?? voiceViewModel.isActive

    if isVoiceActive {
      emojiButton.resignEmojiFocus()
    }

    voiceInputView.isHidden = !isVoiceActive
    textEditor.isHidden = isVoiceActive
    menuButton.isHidden = isVoiceActive
    // Glass divergence: emoji and send share the far-trailing slot. Emoji is
    // available only while the send button is not shown.
    if capabilities.showsEmojiButton {
      emojiButton.isHidden = isVoiceActive || canSend
    }
    attachments.isHidden = isVoiceActive
    attachments.setExternallyCollapsed(isVoiceActive)
    updateGlassSideButtonsHidden(isVoiceActive)
    // Glass divergence: the idle voice affordance is the trailing glass
    // button and remains visible even when text/attachments make it inert.
    voiceButton.isHidden = isVoiceActive
    voiceButton.isEnabled = isVoiceRecordingAvailable(isVoiceActive: isVoiceActive)
    sendButton.isHidden = isVoiceActive || !canSend

    updateSilentModeUI(animated: false, forceLayout: false, isVoiceActive: isVoiceActive)
  }

  private func startVoiceRecording() {
    guard canStartVoiceRecording else { return }
    focusWindowIfNeeded()
    voiceViewModel.requestStart(mode: ComposeVoiceInputMode.selected)
  }

  private func pauseVoiceRecording() {
    if voiceViewModel.inputMode == .transcribe {
      transcribeVoiceRecording(sendText: false)
      return
    }
    let drafts2 = drafts2
    let peerId = peerId
    voiceViewModel.pauseRecording { [weak self] recording in
      let mediaItem = try makeComposeVoiceMediaItem(from: recording)
      let attachment = drafts2.appendAttachment(peer: peerId, media: mediaItem)
      self?.attachmentItems[attachment.id] = mediaItem
      return mediaItem
    }
  }

  private func toggleVoicePlayback() {
    voiceViewModel.togglePlayback()
  }

  private func cancelVoiceRecording() {
    let draftVoiceAttachmentId = voiceViewModel.draftVoiceAttachmentId
    voiceViewModel.cancel()
    if let draftVoiceAttachmentId {
      attachmentItems.removeValue(forKey: draftVoiceAttachmentId)
      drafts2.removeAttachment(peer: peerId, id: draftVoiceAttachmentId)
      drafts2.flushBlocking()
    }
  }

  private func updateVoiceKeyHandlers(phase: ComposeVoiceRecordingPhase) {
    guard phase != .idle else {
      removeVoiceKeyHandlers()
      return
    }

    guard voiceEscapeKeyUnsubscribe == nil,
          voiceReturnKeyUnsubscribe == nil,
          voiceSpaceKeyUnsubscribe == nil
    else { return }

    voiceEscapeKeyUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_voice_escape_\(composeSessionKey)",
      handler: { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.cancelVoiceRecording()
        }
      }
    )

    voiceSpaceKeyUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .spaceKey,
      key: "compose_voice_space_\(composeSessionKey)",
      handler: { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleVoiceSpaceKey()
        }
      }
    )

    if voiceViewModel.inputMode == .transcribe {
      voiceReturnKeyUnsubscribe = dependencies.keyMonitor?.addHandler(
        for: .returnKey,
        key: "compose_voice_return_\(composeSessionKey)",
        handler: { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.sendVoiceRecording()
          }
        }
      )
    }
  }

  private func removeVoiceKeyHandlers() {
    voiceEscapeKeyUnsubscribe?()
    voiceEscapeKeyUnsubscribe = nil
    voiceReturnKeyUnsubscribe?()
    voiceReturnKeyUnsubscribe = nil
    voiceSpaceKeyUnsubscribe?()
    voiceSpaceKeyUnsubscribe = nil
  }

  private func handleVoiceSpaceKey() {
    switch voiceViewModel.phase {
      case .recording:
        pauseVoiceRecording()
      case .review:
        voiceViewModel.togglePlayback()
      case .idle, .starting, .finishing, .transcribing, .transcriptionFailed:
        break
    }
  }

  private func sendVoiceRecording() {
    if voiceViewModel.inputMode == .transcribe {
      transcribeVoiceRecording(sendText: true)
      return
    }
    guard !drafts2.hasPendingAttachments(peer: peerId) else { return }
    Task { @MainActor [weak self] in
      guard let self,
            await voiceViewModel.finalizeRecordingForSend()
      else { return }
      sendFinalizedVoiceRecording()
    }
  }

  private func transcribeVoiceRecording(sendText: Bool) {
    guard !drafts2.hasPendingAttachments(peer: peerId) else { return }
    voiceViewModel.transcribe(sendText: sendText) { [weak self] transcript, shouldSend in
      guard let self, self.window != nil, self.superview != nil else { return }
      let draft = NSMutableAttributedString(attributedString: self.textEditor.attributedString)
      let separator = draft.string.isEmpty || draft.string.last?.isWhitespace == true ? "" : "\n"
      draft.append(self.textEditor.createAttributedString(separator + transcript))
      self.setAttributedString(draft)
      self.saveDraft()
      self.focus()
      if shouldSend { self.send(interpretInlineCommands: false) }
    }
  }

  private func sendFinalizedVoiceRecording() {
    do {
      guard let mediaItem = try voiceViewModel.takeVoiceMediaItem() else { return }

      keepCurrentChatInSidebar()
      Transactions.shared.mutate(
        transaction: .sendMessage(
          TransactionSendMessage(
            text: nil,
            peerId: peerId,
            chatId: chatId ?? 0,
            mediaItems: [mediaItem],
            replyToMsgId: state.replyingToMsgId,
            isSticker: nil,
            entities: nil,
            sendMode: state.sendSilently ? .modeSilent : nil
          )
        )
      )

      clear()

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        if self.messageList?.preservesHistoryOnSend != true { self.state.scrollToBottom() }
      }
    } catch {
      log.error("Failed to send voice recording", error: error)
      ToastCenter.shared.showError("Failed to send voice message")
    }
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

  private func ensureMentionCompletion() {
    guard mentionCompletionMenu == nil else { return }

    let candidateUpdates: AnyPublisher<MentionCompletionCandidates, Never>
    switch usage {
      case .chat:
        guard let chatId else { return }
        let viewModel = InlineKit.ChatParticipantsWithMembersViewModel(
          db: dependencies.database,
          chatId: chatId,
          purpose: .mentionCandidates
        )
        chatParticipantsViewModel = viewModel
        candidateUpdates = viewModel.$mentionCandidates.eraseToAnyPublisher()
      case let .newThread(context):
        candidateUpdates = context.mentionSource.candidateUpdates
    }

    // Create mention completion menu
    mentionCompletionMenu = MentionCompletionMenu(surfaceStyle: .glass)
    mentionCompletionMenu?.delegate = self
    mentionCompletionMenu?.translatesAutoresizingMaskIntoConstraints = false

    // Subscribe to participants updates
    candidateUpdates
      .sink { [weak self] candidates in
        guard let self else { return }
        log.trace("Mention candidates updated: \(candidates.users.count + candidates.groups.count) candidates")
        mentionCandidates = candidates
        applyMentionCandidates()

        if let currentMentionRange,
           mentionCompletionMenu?.hasItems == true,
           mentionCompletionMenu?.isVisible == false
        {
          showMentionCompletion(for: currentMentionRange.query)
        }
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .botAgentsChanged)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.loadMentionAgents(forceRefresh: true)
        }
      }
      .store(in: &cancellables)

    loadMentionAgents()
  }

  private func loadMentionAgents(forceRefresh: Bool = false) {
    guard let chatPeerID else { return }
    mentionAgentsTask?.cancel()
    mentionAgentsTask = Task { @MainActor [weak self, peerId = chatPeerID] in
      guard let self else { return }
      do {
        mentionAgents = try await BotAgentDirectory.shared.agents(for: peerId, forceRefresh: forceRefresh)
      } catch is CancellationError {
        return
      } catch {
        mentionAgents = []
      }
      applyMentionCandidates()
    }
  }

  private func applyMentionCandidates() {
    var candidates = mentionCandidates
    if case .chat = usage {
      candidates.agents = mentionAgents
    }
    mentionCompletionMenu?.updateCandidates(candidates)
  }

  private func refetchMentionParticipantsIfNeeded() {
    guard !didRequestMentionParticipants else { return }
    didRequestMentionParticipants = true

    mentionParticipantsTask?.cancel()
    mentionParticipantsTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self else { return }
      log.trace("Fetching mention candidates from server")
      switch usage {
        case .chat:
          await chatParticipantsViewModel?.refetchParticipants()
        case let .newThread(context):
          await context.mentionSource.refresh()
      }
    }
  }

  private func addMentionMenuToSuperview() {
    guard let menu = mentionCompletionMenu,
          menu.superview == nil,
          let parentView = overlayHostView
    else {
      log.trace("addMentionMenuToSuperview: menu already has superview, is nil, or no overlay host view")
      return
    }

    log.trace("addMentionMenuToSuperview: adding menu to overlay host view")

    // Add the menu to the usage-provided overlay host.
    parentView.addSubview(menu)

    // Remove any existing constraints
    NSLayoutConstraint.deactivate(mentionMenuConstraints)
    mentionMenuConstraints.removeAll()

    mentionMenuConstraints = completionMenuConstraints(for: menu, spacing: 12)

    NSLayoutConstraint.activate(mentionMenuConstraints)
    log.trace("addMentionMenuToSuperview: menu positioned for compose usage")
  }

  private func ensureSlashCommandCompletion() {
    guard peerBotCommandsViewModel == nil else { return }
    peerBotCommandsViewModel = PeerBotCommandsViewModel(peer: peerId)
    commandCompletionMenu = CommandCompletionMenu(surfaceStyle: .glass)
    commandCompletionMenu?.delegate = self
    commandCompletionMenu?.translatesAutoresizingMaskIntoConstraints = false
  }

  private func addCommandMenuToSuperview() {
    guard let menu = commandCompletionMenu,
          menu.superview == nil,
          let parentView = overlayHostView
    else {
      return
    }

    parentView.addSubview(menu)
    NSLayoutConstraint.deactivate(commandMenuConstraints)
    commandMenuConstraints.removeAll()

    commandMenuConstraints = completionMenuConstraints(for: menu, spacing: 12)

    NSLayoutConstraint.activate(commandMenuConstraints)
  }

  private func ensureAutocompleteMenu() {
    guard autocompleteMenu == nil else { return }
    autocompleteMenu = ComposeAutocompleteMenu(surfaceStyle: .glass)
    autocompleteMenu?.delegate = self
    autocompleteMenu?.translatesAutoresizingMaskIntoConstraints = false
  }

  private func addAutocompleteMenuToSuperview() {
    guard let menu = autocompleteMenu,
          menu.superview == nil,
          let parentView = overlayHostView
    else {
      return
    }

    parentView.addSubview(menu)
    NSLayoutConstraint.deactivate(autocompleteMenuConstraints)
    autocompleteMenuConstraints.removeAll()
    autocompleteMenuConstraints = completionMenuConstraints(for: menu, spacing: 12)

    NSLayoutConstraint.activate(autocompleteMenuConstraints)
  }

  private func completionMenuConstraints(for menu: NSView, spacing: CGFloat) -> [NSLayoutConstraint] {
    let anchorView = glassComposePillView ?? self
    let verticalConstraint = switch completionMenuPlacement {
      case .above:
        menu.bottomAnchor.constraint(equalTo: anchorView.topAnchor, constant: -spacing)
      case .below:
        menu.topAnchor.constraint(equalTo: anchorView.bottomAnchor, constant: spacing)
    }
    return [
      menu.leadingAnchor.constraint(equalTo: anchorView.leadingAnchor),
      menu.trailingAnchor.constraint(equalTo: anchorView.trailingAnchor),
      verticalConstraint,
    ]
  }

  private func renderAutocompleteMenu(
    items: [ComposeAutocompleteItem],
    selectedIndex: Int,
    match: ComposeAutocompleteMatch?,
    loadState: ComposeAutocompleteLoadState
  ) {
    let hasCurrentItems = if let match {
      !items.isEmpty && items.allSatisfy { $0.kind == match.kind }
    } else {
      false
    }
    let action = composeAutocompletePresentationAction(
      currentSession: autocompleteMenu?.presentationSession,
      nextMatch: match,
      hasItems: hasCurrentItems,
      loadState: loadState,
      isVisible: autocompleteMenu?.isVisible == true
    )

    switch action {
      case .hide:
        autocompleteMenu?.hide()
        autocompleteKeyMonitorEscUnsubscribe?()
        autocompleteKeyMonitorEscUnsubscribe = nil
        return
      case .retainVisibleContent:
        _ = autocompleteMenu?.retainVisibleContentWhileLoading()
        return
      case .present:
        break
    }

    guard let match else { return }
    ensureAutocompleteMenu()
    addAutocompleteMenuToSuperview()
    autocompleteMenu?.update(
      items: items,
      selectedIndex: selectedIndex,
      match: match
    )
    autocompleteMenu?.show()

    autocompleteKeyMonitorEscUnsubscribe?()
    autocompleteKeyMonitorEscUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_autocomplete_\(composeSessionKey)",
      handler: { [weak self] _ in
        self?.hideAutocomplete(suppressCurrentMatch: true)
      }
    )
  }

  private func showMentionCompletion(for query: String) {
    log.trace("showMentionCompletion: query='\(query)'")
    ensureMentionCompletion()
    guard let mentionCompletionMenu else { return }

    // Ensure menu is added to view hierarchy
    addMentionMenuToSuperview()
    hideCommandCompletion()
    hideAutocomplete()

    mentionCompletionMenu.filterParticipants(with: query)
    mentionCompletionMenu.show()
    refetchMentionParticipantsIfNeeded()

    // Add escape handler for mention menu
    mentionKeyMonitorEscUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_mention_\(composeSessionKey)",
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

  private func showCommandCompletion(for query: String) {
    currentSlashQuery = query
    ensureSlashCommandCompletion()
    addCommandMenuToSuperview()
    hideMentionCompletion()
    hideAutocomplete()

    guard let peerBotCommandsViewModel, let commandCompletionMenu else { return }
    let botSuggestions = peerBotCommandsViewModel.suggestions(matching: query)
      .map { ComposeCommandSuggestion.bot($0) }
    let inlineSuggestions = InlineCommandRegistry.suggestions(matching: query)
      .map { ComposeCommandSuggestion.inline($0) }
    let suggestions = botSuggestions + inlineSuggestions
    commandCompletionMenu.updateSuggestions(suggestions)

    if suggestions.isEmpty {
      commandCompletionMenu.hide()
    } else {
      commandCompletionMenu.show()
      commandKeyMonitorEscUnsubscribe?()
      commandKeyMonitorEscUnsubscribe = dependencies.keyMonitor?.addHandler(
        for: .escape,
        key: "compose_command_\(composeSessionKey)",
        handler: { [weak self] _ in
          self?.hideCommandCompletion()
        }
      )
    }

    if peerBotCommandsViewModel.shouldAttemptLoad {
      Task { @MainActor [weak self] in
        await peerBotCommandsViewModel.ensureLoaded()
        guard self?.currentSlashQuery == query else { return }
        self?.showCommandCompletion(for: query)
      }
    }
  }

  private func hideCommandCompletion() {
    currentSlashCommandRange = nil
    currentSlashQuery = nil
    commandCompletionMenu?.hide()
    commandKeyMonitorEscUnsubscribe?()
    commandKeyMonitorEscUnsubscribe = nil
  }

  private func hideAutocomplete(suppressCurrentMatch: Bool = false) {
    autocompleteViewModel.hide(suppressCurrentMatch: suppressCurrentMatch)
    autocompleteMenu?.hide()
    autocompleteKeyMonitorEscUnsubscribe?()
    autocompleteKeyMonitorEscUnsubscribe = nil
  }

  private var hasVisibleCompletionMenu: Bool {
    mentionCompletionMenu?.isVisible == true ||
      commandCompletionMenu?.isVisible == true ||
      autocompleteMenu?.isVisible == true
  }

  private func installNewThreadScrollObserverIfNeeded() {
    removeNewThreadScrollObserver()
    guard case .newThread = usage,
          let clipView = enclosingScrollView?.contentView
    else {
      return
    }

    clipView.postsBoundsChangedNotifications = true
    newThreadScrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: clipView,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.hideMentionCompletion()
        self?.hideCommandCompletion()
        self?.hideAutocomplete()
      }
    }
  }

  private func removeNewThreadScrollObserver() {
    guard let newThreadScrollObserver else { return }
    NotificationCenter.default.removeObserver(newThreadScrollObserver)
    self.newThreadScrollObserver = nil
  }

  private func detectMentionAtCursor() {
    let cursorPosition = textEditor.textView.selectedRange().location
    let attributedText = textEditor.attributedString
    log.trace("detectMentionAtCursor cursor=\(cursorPosition)")

    if let mentionRange = mentionDetector.detectMentionAt(cursorPosition: cursorPosition, in: attributedText) {
      let isNewMentionSession = currentMentionRange?.range.location != mentionRange.range.location
      currentMentionRange = mentionRange
      if isNewMentionSession {
        loadMentionAgents()
      }
      showMentionCompletion(for: mentionRange.query)
    } else {
      hideMentionCompletion()
    }
  }

  @discardableResult
  private func detectSlashCommandAtCursor() -> Bool {
    let cursorPosition = textEditor.textView.selectedRange().location
    let attributedText = textEditor.attributedString

    if let slashRange = slashCommandDetector.detectSlashCommandAt(cursorPosition: cursorPosition, in: attributedText) {
      currentSlashCommandRange = slashRange
      showCommandCompletion(for: slashRange.query)
      return true
    }

    hideCommandCompletion()
    return false
  }

  private enum ComposeCompletionTrigger {
    case textChange
    case selectionChange
  }

  @discardableResult
  private func detectEmojiAutocompleteAtCursor(trigger: ComposeCompletionTrigger) -> Bool {
    if trigger == .selectionChange, autocompleteMenu?.isVisible != true {
      return false
    }

    let cursorPosition = textEditor.textView.selectedRange().location
    let attributedText = textEditor.attributedString

    if let emojiRange = emojiAutocompleteDetector.detectEmojiAutocompleteAt(
      cursorPosition: cursorPosition,
      in: attributedText
    ) {
      hideMentionCompletion()
      hideCommandCompletion()
      autocompleteViewModel.update(
        match: ComposeAutocompleteMatch(
          kind: .emoji,
          range: emojiRange.range,
          query: emojiRange.query
        )
      )
      return true
    }

    if autocompleteViewModel.match?.kind == .emoji {
      hideAutocomplete()
    }

    return false
  }

  @discardableResult
  private func detectThreadAutocompleteAtCursor() -> Bool {
    let cursorPosition = textEditor.textView.selectedRange().location
    let attributedText = textEditor.attributedString

    if let threadRange = threadLinkDetector.detectThreadLinkAt(cursorPosition: cursorPosition, in: attributedText) {
      hideMentionCompletion()
      hideCommandCompletion()
      autocompleteViewModel.configure(spaceId: chat?.spaceId)
      autocompleteViewModel.update(
        match: ComposeAutocompleteMatch(
          kind: .thread,
          range: threadRange.range,
          query: threadRange.query
        )
      )
      return true
    }

    if let referenceRange = threadLinkDetector.detectThreadNumberReferenceAt(
      cursorPosition: cursorPosition,
      in: attributedText
    ) {
      hideMentionCompletion()
      hideCommandCompletion()
      autocompleteViewModel.configure(spaceId: chat?.spaceId)
      autocompleteViewModel.update(
        match: ComposeAutocompleteMatch(
          kind: .threadNumber,
          range: referenceRange.range,
          query: referenceRange.query
        )
      )
      return true
    }

    hideAutocomplete()
    return false
  }

  private func detectComposeCompletionsAtCursor(trigger: ComposeCompletionTrigger) {
    let selectedRange = textEditor.textView.selectedRange()
    guard selectedRange.location != NSNotFound,
          selectedRange.length == 0,
          !textEditor.textView.hasMarkedText()
    else {
      hideMentionCompletion()
      hideCommandCompletion()
      hideAutocomplete()
      return
    }

    if trigger == .selectionChange,
       !hasVisibleCompletionMenu,
       autocompleteViewModel.match == nil
    {
      hideMentionCompletion()
      hideCommandCompletion()
      hideAutocomplete()
      return
    }

    if case .newThread = usage {
      if detectEmojiAutocompleteAtCursor(trigger: trigger) {
        return
      }
      if detectThreadAutocompleteAtCursor() {
        return
      }
      detectMentionAtCursor()
      return
    }

    if detectSlashCommandAtCursor() {
      hideAutocomplete()
      return
    }
    if detectEmojiAutocompleteAtCursor(trigger: trigger) {
      return
    }
    if detectThreadAutocompleteAtCursor() {
      return
    }
    detectMentionAtCursor()
  }

  // MARK: - Public Interface

  var text: String {
    get { textEditor.string }
    set { textEditor.string = newValue }
  }

  func focusEditor() {
    guard messageList?.isMessageSelectionActive != true else { return }
    guard !currentVoiceActive else { return }
    textEditor.focus()
  }

  // MARK: - Height

  private var currentAccessoryBarHeight: CGFloat {
    isAccessoryBarExpanded ? layout.accessoryBarHeight : 0
  }

  private func setAccessoryBarExpanded(_ expanded: Bool) {
    guard layout == .accessoryBar,
          isAccessoryBarExpanded != expanded,
          let glassAccessoryBarView
    else {
      return
    }

    isAccessoryBarExpanded = expanded
    setNewThreadEscapeHandlerEnabled(expanded)
    if expanded {
      glassAccessoryBarView.isHidden = false
      // Grow the outer Compose constraint before making the chin mandatory.
      // Keeping this internal transition ordered avoids a transient
      // unsatisfiable 42 = editor + chin + inset.
      updateHeight(animate: false)
    }
    glassAccessoryHeightConstraint?.constant = currentAccessoryBarHeight
    if !expanded {
      // Remove the chin requirement before shrinking the outer constraint.
      updateHeight(animate: false)
    }
    glassAccessoryBarView.alphaValue = expanded ? 1 : 0
    glassAccessoryBarView.isHidden = !expanded
  }

  private func setNewThreadEscapeHandlerEnabled(_ enabled: Bool) {
    newThreadEscapeKeyUnsubscribe?()
    newThreadEscapeKeyUnsubscribe = nil
    guard enabled, case .newThread = usage else { return }

    newThreadEscapeKeyUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_new_thread_\(composeSessionKey)",
      handler: { [weak self] _ in
        self?.collapseNewThreadComposeAndResignFocus()
      }
    )
  }

  private func collapseNewThreadComposeAndResignFocus() {
    guard case .newThread = usage else { return }
    hideMentionCompletion()
    hideCommandCompletion()
    hideAutocomplete()
    window?.makeFirstResponder(nil)
    setAccessoryBarExpanded(false)
  }

  private func getTextViewHeight(isVoiceActive: Bool? = nil) -> CGFloat {
    if isVoiceActive ?? currentVoiceActive {
      textViewHeight = textEditor.minHeight
      return textViewHeight
    }

    textViewHeight = glassTextViewHeight(for: textEditor.textView)

    return textViewHeight
  }

  private func glassTextViewHeight(for textView: NSTextView) -> CGFloat {
    // Glass divergence: keep the compact input-style vertical insets, but
    // measure actual layout height so soft wraps grow like explicit newlines.
    let contentHeight = contentHeight(for: textView)
    let insetHeight = textView.textContainerInset.height * 2
    let measuredHeight = ceil(contentHeight + insetHeight)
    return min(300.0, max(textEditor.minHeight, measuredHeight))
  }

  private func updateHeightForTextLayoutWidthChange() {
    guard !currentVoiceActive else { return }

    // Glass content can finish layout after the chat's viewDidLayout callback.
    // Resolve the whole compose subtree before reading the width: laying out
    // only the editor leaves its glass ancestors' pending width changes behind.
    layoutSubtreeIfNeeded()
    let textLayoutWidth = textEditor.textView.bounds.width
    guard textLayoutWidth > 1 else { return }
    guard abs(lastMeasuredTextLayoutWidth - textLayoutWidth) >= 0.5 else { return }

    lastMeasuredTextLayoutWidth = textLayoutWidth
    if textEditor.isAttributedTextEmpty {
      return
    }

    // Glass divergence: soft-wrap height depends on the resolved text width,
    // so window resizing must remeasure even when the text itself did not edit.
    updateHeightIfNeeded(for: textEditor.textView, animate: false)
  }

  private func getChromeHeight(textEditorHeight: CGFloat) -> CGFloat {
    max(textEditorHeight, controlMode.glassControlsMinHeight) +
      currentAccessoryBarHeight +
      viewportBottomInset
  }

  /// Get compose wrapper height
  private func getHeight(isVoiceActive: Bool? = nil) -> CGFloat {
    let voiceActive = isVoiceActive ?? currentVoiceActive
    let textEditorHeight = getTextViewHeight(isVoiceActive: voiceActive)
    var height = getChromeHeight(textEditorHeight: textEditorHeight)

    // Reply view
    if case .chat = usage {
      if state.replyingToMsgId != nil || state.editingMsgId != nil || state.forwardContext != nil {
        height += Theme.embeddedMessageHeight
      }
    }

    if !voiceActive {
      height += attachments.getHeight()
    }

    return height
  }

  func updateHeight(animate: Bool = false, voicePhase: ComposeVoiceRecordingPhase? = nil) {
    let isVoiceActive = voicePhase.map { $0 != .idle }
    let textEditorHeight = getTextViewHeight(isVoiceActive: isVoiceActive)
    let wrapperHeight = getHeight(isVoiceActive: isVoiceActive)

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
        // Glass divergence: text insets stay input-style and fixed; do not run
        // legacy dynamic recentering/caret reset on every height update.
        attachments.updateHeight(animated: true)
        messageList?.updateInsetForCompose(wrapperHeight)
        // NSAnimationContext.endGrouping()
      }
    } else {
      textEditor.setHeight(textEditorHeight)
      // Glass divergence: text insets stay input-style and fixed; do not run
      // legacy dynamic recentering/caret reset on every height update.
      heightConstraint.constant = wrapperHeight
      textHeightConstraint.constant = textEditorHeight
      attachments.updateHeight(animated: false)
      messageList?.updateInsetForCompose(wrapperHeight)
    }

    if case let .newThread(context) = usage {
      context.didChangeHeight(wrapperHeight)
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

    mentionMenuConstraints = completionMenuConstraints(for: menu, spacing: 12)

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
      key: "compose_reply_\(composeSessionKey)",
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
          let attributedString = ExperimentalFeatureFlags.richMessageCopyEditingEnabled ? MessageMarkdown.editableText(
            text: message.message.text ?? "",
            entities: message.message.entities,
            configuration: .init(
              font: ComposeTextEditor.font,
              primaryColor: ComposeTextEditor.textColor,
              linkColor: ComposeTextEditor.linkColor,
              convertMentionsToLink: false
            )
          ) : toAttributedString(
            text: message.message.text ?? "",
            entities: message.message.entities
          )

          // TODO: Extract these to a function
          // set manually without updating height
          textEditor.replaceAttributedString(attributedString)
          textEditor.showPlaceholder(text.isEmpty)
          updateSendButtonIfNeeded()
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
    guard canMutateDraft else { return }

    // Format
    let preferredImageFormat: ImageFormat? = if let url {
      url.pathExtension.lowercased() == "png" ? ImageFormat.png : ImageFormat.jpeg
    } else { nil }

    // Check aspect ratio
    if shouldSendAsFile(image) {
      if let url {
        addFile(url)
        return
      }

      let tempDir = FileHelpers.getTrueTemporaryDirectory()
      let result = try? image.save(
        to: tempDir,
        withName: "image\(preferredImageFormat?.toExt() ?? ".jpg")",
        format: preferredImageFormat ?? .jpeg
      )
      if let (_, url) = result {
        addFile(url)
      } else {
        ToastCenter.shared.showError("Couldn’t add attachment as media or a file.")
      }
      return
    }

    let pendingId: String = switch usage {
      case .chat:
        drafts2.addImage(
          peer: peerId,
          image: image,
          preferredFormat: preferredImageFormat,
          fallbackURL: url
        )
      case let .newThread(context):
        context.attachmentStore.addImage(
          image,
          preferredFormat: preferredImageFormat,
          fallbackURL: url,
          completion: { [weak self] result in self?.handleDraftAttachmentResult(result) }
        )
    }
    attachments.addImageView(image, id: pendingId)
    updateHeight(animate: true)
    notifyNewThreadDraftChanged()
  }

  func removeImage(_ id: String) {
    // Update UI
    attachments.removeImageView(id: id)
    updateHeight(animate: true)

    // Update state
    attachmentItems.removeValue(forKey: id)
    removeStoredAttachment(id: id)
  }

  private func isVideoFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
  }

  private func isAnimatedImageFile(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "gif"
  }

  private func loadThumbnail(from photoInfo: PhotoInfo?) -> NSImage? {
    guard let localPath = photoInfo?.bestPhotoSize()?.localPath else { return nil }
    let url = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(localPath)
    return NSImage(contentsOf: url)
  }

  @MainActor
  func addVideo(_ url: URL, thumbnail: NSImage? = nil) async {
    guard canMutateDraft else { return }

    let pendingId: String = switch usage {
      case .chat:
        drafts2.addVideo(peer: peerId, url: url, thumbnail: thumbnail)
      case let .newThread(context):
        context.attachmentStore.addVideo(
          url,
          thumbnail: thumbnail,
          completion: { [weak self] result in self?.handleDraftAttachmentResult(result) }
        )
    }
    attachments.addVideoView(thumbnail: thumbnail, videoURL: url, id: pendingId)
    updateHeight(animate: true)
  }

  @MainActor
  func addAnimatedImage(_ url: URL) async {
    guard canMutateDraft else { return }

    let thumbnail = NSImage(contentsOf: url)
    let pendingId: String = switch usage {
      case .chat:
        drafts2.addAnimatedImage(peer: peerId, url: url)
      case let .newThread(context):
        context.attachmentStore.addAnimatedImage(
          url,
          completion: { [weak self] result in self?.handleDraftAttachmentResult(result) }
        )
    }
    attachments.addVideoView(thumbnail: thumbnail, videoURL: nil, id: pendingId)
    updateHeight(animate: true)
  }

  func removeVideo(_ id: String) {
    attachments.removeVideoView(id: id)
    attachmentItems.removeValue(forKey: id)
    removeStoredAttachment(id: id)
    updateHeight(animate: true)
  }

  @discardableResult
  func addFile(_ url: URL) -> Bool {
    guard canMutateDraft else { return false }

    let pendingId: String = switch usage {
      case .chat:
        drafts2.addFile(peer: peerId, url: url)
      case let .newThread(context):
        context.attachmentStore.addFile(
          url,
          completion: { [weak self] result in self?.handleDraftAttachmentResult(result) }
        )
    }
    attachments.addPendingDocument(url: url, id: pendingId)
    updateHeight(animate: true)
    return true
  }

  func removeFile(_ id: String) {
    // TODO: Delete from file cache as well

    // Update UI
    attachments.removeDocumentView(id: id)
    updateHeight(animate: true)

    // Update state
    attachmentItems.removeValue(forKey: id)
    removeStoredAttachment(id: id)
  }

  private func removeStoredAttachment(id: String) {
    switch usage {
      case .chat:
        drafts2.removeAttachment(peer: peerId, id: id)
      case let .newThread(context):
        context.attachmentStore.remove(id: id)
    }
    notifyNewThreadDraftChanged()
  }

  func clearAttachments(updateHeights: Bool = false) {
    attachmentItems.removeAll()
    attachments.clearViews()
    if updateHeights {
      updateHeight()
    }
  }

  /// Clear, reset height
  func clear() {
    switch usage {
      case .chat:
        voiceViewModel.cancel()
        attachmentItems.removeAll()
        state.clearReplyingToMsgId()
        state.clearEditingMsgId()
        state.clearForwarding()
        clearDraft(flush: true)
      case let .newThread(context):
        attachmentItems.removeAll()
        context.attachmentStore.clear()
    }

    // Views
    attachments.clearViews()
    textViewContentHeight =
      textEditor
        .getTypingLineHeight() // manually for now, FIXME: make it automatic in texteditor.clear
    textEditor.clear()
    clearAttachments(updateHeights: false)
    updateSendButtonIfNeeded()

    // must be last call
    updateHeight()
  }

  /// Send the message
  func send(sendMode: MessageSendMode? = nil, interpretInlineCommands: Bool = true) {
    guard messageList?.isMessageSelectionActive != true else { return }
    textEditor.textView.resetPastedLinks()
    if case let .newThread(context) = usage {
      sendNewThread(using: context, intent: .openThread)
      return
    }

    if voiceViewModel.phase == .review {
      sendVoiceRecording()
      return
    }
    if voiceViewModel.isActive {
      return
    }

    // DispatchQueue.main.async(qos: .userInteractive) {
    ignoreNextHeightChange = true
    let attributedString = trimmedAttributedString(textEditor.attributedString)
    let replyToMsgId = state.replyingToMsgId
    let attachmentItemsSnapshot = drafts2.load(peer: peerId)?.attachments.map(\.media) ?? Array(attachmentItems.values)
    let destinationPeerId = peerId
    let destinationChatId = chatId ?? 0
    // keep a copy of editingMessageId before we clear it
    let editingMessageId = state.editingMsgId
    let forwardContext = state.forwardContext

    // Extract mention entities from attributed text
    // TODO: replace with `fromAttributedString`
    let (rawText, entities) = ProcessEntities.fromAttributedString(
      attributedString,
      threadLinkSpaceId: chat?.spaceId
    )

    let hasText = !rawText.isEmpty
    let hasAttachments = !attachmentItemsSnapshot.isEmpty

    let hasBotCommandEntity = entities.entities.contains { entity in
      if case .botCommand = entity.entity { return true }
      return false
    }
    if interpretInlineCommands,
       editingMessageId == nil,
       forwardContext == nil,
       !hasAttachments,
       !hasBotCommandEntity,
       let action = InlineCommandRegistry.action(forStandaloneText: rawText)
    {
      ignoreNextHeightChange = false
      performInlineCommand(action)
      return
    }

    // make it nil if empty
    let text = if rawText.isEmpty, hasAttachments {
      nil as String?
    } else {
      rawText
    }
    let effectiveSendMode = sendMode ?? (state.sendSilently ? .modeSilent : nil)

    func enqueueAttachments(replyToMessageId: Int64?) {
      for (index, attachment) in attachmentItemsSnapshot.enumerated() {
        let isFirst = index == 0
        Transactions.shared.mutate(
          transaction:
          .sendMessage(
            TransactionSendMessage(
              text: isFirst ? text : nil,
              peerId: destinationPeerId,
              chatId: destinationChatId, // FIXME: chatId fallback
              mediaItems: [attachment],
              replyToMsgId: isFirst ? replyToMessageId : nil,
              isSticker: nil,
              entities: isFirst ? entities : nil,
              sendMode: effectiveSendMode
            )
          )
        )
      }
    }

    if !canSend { return }

    // Edit message
    if let editingMessageId {
      mentionedParticipants.handle(entities: entities, peer: destinationPeerId, chat: chat) {
        Task.detached(priority: .userInitiated) { // @MainActor in
          try await Api.realtime.send(.editMessage(
            messageId: editingMessageId,
            text: text ?? "",
            chatId: destinationChatId,
            peerId: destinationPeerId,
            entities: entities
          ))
        }
      }
    }

    // Forward message
    else if let forwardContext {
      guard !forwardContext.messageIds.isEmpty else {
        log.error("Forward failed: empty message ids")
        return
      }

      keepCurrentChatInSidebar()

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
              sendMode: effectiveSendMode
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
      keepCurrentChatInSidebar()

      mentionedParticipants.handle(entities: entities, peer: destinationPeerId, chat: chat) {
        Task.detached(priority: .userInitiated) { // @MainActor in
          try await Api.realtime.send(
            .sendMessage(
              text: text,
              peerId: destinationPeerId,
              chatId: destinationChatId, // FIXME: chatId fallback
              replyToMsgId: replyToMsgId,
              isSticker: nil,
              entities: entities,
              sendMode: effectiveSendMode
            )
          )
        }
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
      keepCurrentChatInSidebar()
      mentionedParticipants.handle(entities: entities, peer: destinationPeerId, chat: chat) {
        enqueueAttachments(replyToMessageId: replyToMsgId)
      }
    }

    // Clear immediately
    clear()

    // Cancel typing
    Task {
      await ComposeActions.shared.stoppedTyping(for: self.peerId)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      // Scroll to new message
      if self.messageList?.preservesHistoryOnSend != true { self.state.scrollToBottom() }
    }

    ignoreNextHeightChange = false
    // }
  }

  func configureNewThreadSendTooltip(placement: InlineTooltipPlacement) {
    guard case .newThread = usage else { return }
    sendButton.setInlineTooltip(
      "Create and open thread",
      description: "Option-Return creates and sends without opening it.",
      shortcut: InlineTooltipShortcut("\r"),
      placement: placement
    )
    if capabilities.showsSilentModeToggle {
      silentModeButton.setInlineTooltip(
        "Silent mode",
        description: "Send without notifying people. This choice is remembered for new threads.",
        placement: placement
      )
    }
  }

  private func sendNewThread(
    using context: NewThreadComposeContext,
    intent: NewThreadComposeSubmissionIntent
  ) {
    guard canSend, !isSubmittingNewThread else { return }
    guard let authorUserID = dependencies.auth.currentUserId else {
      ToastCenter.shared.showError("You're signed out. Please log in again.")
      return
    }

    let attributedString = trimmedAttributedString(textEditor.attributedString)
    let (rawText, entities) = ProcessEntities.fromAttributedString(
      attributedString,
      parseMarkdown: false,
      threadLinkSpaceId: context.destination().spaceID
    )
    let draft = PreparedNewThreadDraft(
      authorUserID: authorUserID,
      text: rawText,
      entities: entities,
      attachments: context.attachmentStore.attachments,
      destination: context.destination(),
      sendSilently: context.sendSilently(),
      agentContext: context.agentContext()
    )
    guard !draft.isEmpty else { return }

    isSubmittingNewThread = true
    setNewThreadAuthoringEnabled(false)
    updateSendButtonIfNeeded()

    Task { @MainActor [weak self] in
      let result = await context.submit(draft, intent)
      // Submission feedback belongs to the host, not this view's lifetime.
      // An early navigation may tear Compose down while the send is still
      // finishing, but failures must still reach the user.
      context.didFinishSubmission(result)
      guard let self else { return }
      isSubmittingNewThread = false
      setNewThreadAuthoringEnabled(true)

      switch result {
        case .success:
          clear()
          collapseNewThreadComposeAndResignFocus()
        case let .failure(failure) where failure.createdPeer != nil:
          // The submission contract has installed the content as a real draft
          // on that peer, so clearing here cannot lose the user's work.
          clear()
          collapseNewThreadComposeAndResignFocus()
        case .failure:
          updateSendButtonIfNeeded()
      }
    }
  }

  private func setNewThreadAuthoringEnabled(_ enabled: Bool) {
    guard case .newThread = usage else { return }
    textEditor.textView.isEditable = enabled
    menuButton.isEnabled = enabled
    silentModeButton.isEnabled = enabled
    if !enabled {
      hideMentionCompletion()
      hideCommandCompletion()
      hideAutocomplete()
    }
  }

  private func performInlineCommand(_ action: InlineCommandAction, fromMenu: Bool = false) {
    guard inlineCommandTask == nil else { return }
    let invocationPeerId = peerId
    let invocationText = textEditor.plainText
    let invocationAttributedText = NSAttributedString(attributedString: textEditor.attributedString)
    let normalizedInvocation = invocationText.trimmingCharacters(in: .whitespacesAndNewlines)
    let replyingToMsgId = state.replyingToMsgId
    guard fromMenu || (normalizedInvocation.hasPrefix("/") &&
          !normalizedInvocation.dropFirst().contains(where: { $0.isWhitespace })),
          state.editingMsgId == nil,
          state.forwardContext == nil,
          attachmentItems.isEmpty,
          !drafts2.hasPendingAttachments(peer: invocationPeerId),
          !voiceViewModel.isActive
    else { return }

    hideCommandCompletion()
    inlineCommandTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { inlineCommandTask = nil }
      do {
        let execution: InlineCommandExecution
        switch action {
        case .renameThread:
          guard invocationPeerId.asThreadId() != nil else {
            ToastCenter.shared.showError("Only threads can be renamed.")
            return
          }
          focusWindowIfNeeded()
          guard MainWindowOpenCoordinator.shared.isViewingChat(invocationPeerId),
                MainWindowOpenCoordinator.shared.renameThread()
          else {
            ToastCenter.shared.showError("Couldn’t open title editing for this thread.")
            return
          }
          execution = .completed
        case .collapseHistory:
          guard let messageList,
                let maxID = messageList.highestPositiveMessageId
          else { return }
          try await messageList.collapseHistory(maxID: maxID)
          execution = .completed
        case .createSubthread:
          guard let parentChatId = chatId else { return }
          let result = try await LocalThreadCommandService.createAndOpen(parentChatId: parentChatId) {
            [realtimeV2 = dependencies.realtimeV2] transaction in
            try await realtimeV2.send(transaction)
          }
          execution = .openThread(result)
        }

        guard window != nil, peerId == invocationPeerId else { return }
        let invocationIsUnchanged = textEditor.plainText == invocationText &&
          textEditor.attributedString.isEqual(to: invocationAttributedText) &&
          state.replyingToMsgId == replyingToMsgId &&
          state.editingMsgId == nil &&
          state.forwardContext == nil &&
          attachmentItems.isEmpty &&
          !drafts2.hasPendingAttachments(peer: invocationPeerId) &&
          !voiceViewModel.isActive
        if !fromMenu, invocationIsUnchanged {
          clearInlineCommandText()
        }

        if case let .openThread(result) = execution {
          dependencies.openChatRoute(peer: result.peer)
          if !result.didOpenInSidebar {
            ToastCenter.shared.showError("Thread created, but couldn’t open it in the sidebar.")
          }
        }
      } catch {
        guard window != nil, peerId == invocationPeerId else { return }
        log.error("Inline command failed", error: error)
        ToastCenter.shared.showError(error.localizedDescription)
      }
    }
  }

  private func clearInlineCommandText() {
    textViewContentHeight = textEditor.getTypingLineHeight()
    textEditor.clear()
    clearDraft()
    updateSendButtonIfNeeded()
    updateHeight()
  }

  private enum InlineCommandExecution {
    case completed
    case openThread(LocalThreadCommandResult)
  }

  private func commandLaunchState() -> ComposeCommandLaunchState {
    guard case .chat = usage else { return .blocked }
    return ComposeCommandLaunchState(
      text: textEditor.plainText,
      isEditing: state.editingMsgId != nil,
      isForwarding: state.forwardContext != nil,
      hasAttachments: !attachmentItems.isEmpty,
      hasPendingAttachments: drafts2.hasPendingAttachments(peer: peerId),
      isVoiceActive: voiceViewModel.isActive
    )
  }

  private func showCommandsFromMenu() {
    switch commandLaunchState() {
      case .blocked:
        return
      case .empty:
        insertSlashAndShowCommands()
      case .text:
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear message to show commands?"
        alert.informativeText = "Commands only work when the message is empty."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear and Show Commands")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
          guard response == .alertFirstButtonReturn else { return }
          self?.clearInlineCommandText()
          self?.insertSlashAndShowCommands()
        }
    }
  }

  private func insertSlashAndShowCommands() {
    guard commandLaunchState() == .empty else { return }
    if !textEditor.plainText.isEmpty {
      clearInlineCommandText()
    }
    focusWindowIfNeeded()
    focus()
    textEditor.insertText("/")
    _ = detectSlashCommandAtCursor()
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

  private func keepCurrentChatInSidebar() {
    SidebarState.shared.keepInSidebar(peerId)
  }

  func sendSticker(_ image: NSImage) {
    let replyToMsgId = state.replyingToMsgId
    let sendMode: MessageSendMode? = state.sendSilently ? .modeSilent : nil

    keepCurrentChatInSidebar()

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
              entities: nil,
              sendMode: sendMode
            )
          )
        )
      } catch {
        self.log.error("Failed to send sticker", error: error)
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if self.messageList?.preservesHistoryOnSend != true { self.state.scrollToBottom() }
    }
  }

  func focus() {
    guard messageList?.isMessageSelectionActive != true else { return }
    guard !currentVoiceActive else { return }
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
    updateSendButtonIfNeeded()
  }

  func acceptExternalDraft(_ text: String, for peer: InlineKit.Peer) -> Bool {
    guard chatPeerID == peer else { return false }
    if !text.isEmpty {
      guard commandLaunchState() == .empty else { return false }
      setText(text)
      _ = saveDraft()
    }
    focusEditor()
    return true
  }

  func isComposer(for peer: InlineKit.Peer) -> Bool { chatPeerID == peer }

  private var keyMonitorUnsubscribe: (() -> Void)?
  private var keyMonitorPasteUnsubscribe: (() -> Void)?
  private var smartLinkEscapeKeyUnsubscribe: (() -> Void)?

  private func setSmartLinkEscapeHandlerEnabled(_ enabled: Bool) {
    smartLinkEscapeKeyUnsubscribe?()
    smartLinkEscapeKeyUnsubscribe = nil
    guard enabled else { return }

    smartLinkEscapeKeyUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .escape,
      key: "compose_smart_link_\(composeSessionKey)",
      handler: { [weak self] _ in
        self?.textEditor.textView.revertLatestSmartLink()
      }
    )
  }

  private func setupKeyDownHandler() {
    keyMonitorUnsubscribe = dependencies.keyMonitor?.addHandler(
      for: .textInputCatchAll,
      key: textInputMonitorKey,
      handler: { [weak self] event in
        guard let self else { return }
        guard !currentVoiceActive else { return }

        guard messageList?.isMessageSelectionActive != true else { return }

        // Only allow valid printable characters, not control/navigation keys
        guard let characters = event.characters,
              characters != " ", // Ignore space as it prevents our image preview from working
              !characters.isEmpty,
              characters.allSatisfy({ char in
                // Check if character is printable (not a control character)
                if let scalar = char.unicodeScalars.first {
                  return scalar.properties.isAlphabetic ||
                    scalar.properties.isMath ||
                    char == "@" ||
                    char == "/"
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
      key: "compose_paste_\(composeSessionKey)",
      handler: { [weak self] _ in
        self?.handleGlobalPaste()
      }
    )
  }

  private func handleGlobalPaste() {
    guard messageList?.isMessageSelectionActive != true else { return }
    guard !currentVoiceActive, canMutateDraft else { return }

    let pasteboard = NSPasteboard.general

    // If this is non-text content, route through attachments.
    if handleAttachments(from: pasteboard) { return }

    // Otherwise, perform a native plain-text paste (ComposeNSTextView disables rich paste for reliability).
    focus()
    textEditor.textView.paste(nil)
  }

  deinit {
    inlineCommandTask?.cancel()
    if case .chat = usage {
      requestImmediateDraftPersistenceIfNeeded()
    }
    draftAttachmentObserverCancel?()
    draftAttachmentObserverCancel = nil
    draftEntitySaveTask?.cancel()
    draftEntitySaveTask = nil
    cancellables.removeAll()

    // Clean up
    keyMonitorUnsubscribe?()
    keyMonitorUnsubscribe = nil
    keyMonitorPasteUnsubscribe?()
    keyMonitorPasteUnsubscribe = nil
    smartLinkEscapeKeyUnsubscribe?()
    smartLinkEscapeKeyUnsubscribe = nil
    newThreadEscapeKeyUnsubscribe?()
    newThreadEscapeKeyUnsubscribe = nil
    removeVoiceKeyHandlers()

    // Clean up mention resources
    mentionKeyMonitorEscUnsubscribe?()
    mentionKeyMonitorEscUnsubscribe = nil
    NSLayoutConstraint.deactivate(mentionMenuConstraints)
    mentionMenuConstraints.removeAll()
    mentionCompletionMenu?.removeFromSuperview()
    mentionParticipantsTask?.cancel()
    mentionParticipantsTask = nil
    mentionAgentsTask?.cancel()
    mentionAgentsTask = nil

    if case .newThread = usage {
      autocompleteKeyMonitorEscUnsubscribe?()
      autocompleteKeyMonitorEscUnsubscribe = nil
      removeNewThreadScrollObserver()
      NSLayoutConstraint.deactivate(autocompleteMenuConstraints)
      autocompleteMenuConstraints.removeAll()
      autocompleteMenu?.removeFromSuperview()
    }

    log.trace("deinit")
  }
}

// MARK: External Interface for file drop

extension GlassComposeAppKit {
  @discardableResult
  func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
    guard !currentVoiceActive, canMutateDraft else { return false }
    guard textEditor.textView.handleAttachments(from: pasteboard, includeText: false) else {
      return false
    }

    focus()
    return true
  }

  func handleFileDrop(_ urls: [URL]) {
    guard !currentVoiceActive, canMutateDraft else { return }

    for url in urls {
      if isAnimatedImageFile(url) {
        handleAnimatedImageDropOrPaste(url)
      } else if isVideoFile(url) {
        handleVideoDropOrPaste(url)
      } else {
        addFile(url)
      }
    }
  }

  func handleTextDropOrPaste(_ text: String) {
    guard !currentVoiceActive, canMutateDraft else { return }

    textEditor.insertText(text)
    focusWindowIfNeeded()
    focus()
  }

  func handleImageDropOrPaste(_ image: NSImage, _ url: URL? = nil) {
    guard !currentVoiceActive, canMutateDraft else { return }

    addImage(image, url)
    focusWindowIfNeeded()
    focus()
  }

  func handleVideoDropOrPaste(_ url: URL, thumbnail: NSImage? = nil) {
    guard !currentVoiceActive, canMutateDraft else { return }
    Task { [weak self] in await self?.addVideo(url, thumbnail: thumbnail) }
  }

  func handleAnimatedImageDropOrPaste(_ url: URL) {
    guard !currentVoiceActive, canMutateDraft else { return }
    Task { [weak self] in await self?.addAnimatedImage(url) }
  }
}

// MARK: Delegate

private enum ComposeAutocompleteArrowDirection {
  case previous
  case next
}

extension GlassComposeAppKit: NSTextViewDelegate, ComposeTextViewDelegate {
  /// Implement delegate methods as needed
  func textViewDidPressCommandReturn(_ textView: NSTextView) -> Bool {
    // Always send with command enter
    send()
    return true // handled
  }

  func textViewDidPressOptionReturn(_ textView: NSTextView) -> Bool {
    guard case let .newThread(context) = usage else { return false }
    sendNewThread(using: context, intent: .stayInCurrentView)
    return true
  }

  func textViewDidPressArrowUp(_ textView: NSTextView, event: NSEvent) -> Bool {
    guard shouldHandlePlainComposeArrow(textView, event: event) else { return false }

    if autocompleteMenu?.isVisible == true {
      return handleAutocompleteArrow(.previous)
    }

    if commandCompletionMenu?.isVisible == true {
      commandCompletionMenu?.selectPrevious()
      return true
    }

    // If mention menu is visible, let it handle the arrow key
    if mentionCompletionMenu?.isVisible == true {
      mentionCompletionMenu?.selectPrevious()
      return true
    }

    // only if empty
    guard textView.string.count == 0 else { return false }
    guard case .chat = usage else { return false }

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
    if handleAutocompleteCommitKey() { return true }

    if let commandCompletionMenu,
       commandCompletionMenu.isVisible,
       commandCompletionMenu.selectCurrentItem(sendAfterInsertion: true)
    {
      return true
    }

    // If mention menu is visible, select current item with Enter
    if let mentionCompletionMenu, mentionCompletionMenu.isVisible {
      if mentionCompletionMenu.selectCurrentItem() {
        return true
      }
    }

    if case .newThread = usage {
      send()
      return true
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
    handleVideoDropOrPaste(url)
  }

  func textView(_ textView: NSTextView, didReceiveAnimatedImage url: URL) {
    handleAnimatedImageDropOrPaste(url)
  }

  func textView(_ textView: NSTextView, didFailToPasteAttachment failure: PasteboardAttachmentFailure) {
    ToastCenter.shared.showError(failure.userFacingMessage)
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

    let threadLinkRanges = ComposeThreadLinkEditing.affectedThreadLinkRanges(
      in: textView.attributedString(),
      changeRange: affectedCharRange
    )
    if !threadLinkRanges.isEmpty, let textStorage = textView.textStorage {
      textStorage.beginEditing()
      ComposeThreadLinkEditing.stripThreadLinks(
        in: textStorage,
        ranges: threadLinkRanges,
        textColor: NSColor.labelColor
      )
      textStorage.endEditing()
      textView.resetTypingAttributesToDefault()
    }

    return true
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    paragraphDirectionController.textDidChange()

    // Prevent mention style leakage to new text
    textView.updateTypingAttributesIfNeeded()

    if !ignoreNextHeightChange {
      updateHeightIfNeeded(for: textView)
    } else {
      log.trace("ignore next height change")
    }

    detectComposeCompletionsAtCursor(trigger: .textChange)

    if case .chat = usage {
      handleStickerDetectionIfNeeded(for: textView)
    }

    if textEditor.isAttributedTextEmpty {
      // Handle empty text
      textEditor.showPlaceholder(true)

      if case .chat = usage {
        Task {
          await ComposeActions.shared.stoppedTyping(for: self.peerId)
        }
      }
    } else {
      // Handle non-empty text
      textEditor.showPlaceholder(false)

      if case .chat = usage {
        Task {
          await ComposeActions.shared.startedTyping(for: self.peerId)
        }
      }
    }

    updateSendButtonIfNeeded()
    switch usage {
      case .chat:
        saveDraftWithDebounce()
      case .newThread:
        notifyNewThreadDraftChanged()
    }
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

  private func notifyNewThreadDraftChanged() {
    guard case let .newThread(context) = usage else { return }
    let (rawText, entities) = ProcessEntities.fromAttributedString(
      textEditor.attributedString,
      parseMarkdown: false,
      threadLinkSpaceId: context.destination().spaceID
    )
    let hasAttachments = !context.attachmentStore.attachments.isEmpty || context.attachmentStore.hasPendingAttachments
    if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments {
      setAccessoryBarExpanded(true)
    }
    context.didChangeDraft(rawText, entities, hasAttachments)
  }

  /// Reflect state changes in send button
  func updateSendButtonIfNeeded() {
    sendButton.updateCanSend(canSend)
    updateVoiceAvailability()
  }

  func calculateContentHeight(for textView: NSTextView) -> CGFloat {
    contentHeight(for: textView)
  }

  func updateContentHeight(for textView: NSTextView) {
    textViewContentHeight = calculateContentHeight(for: textView)
  }

  func updateHeightIfNeeded(for textView: NSTextView, animate: Bool = false) {
    let currentTextHeight = max(textEditor.minHeight, textViewHeight)
    let nextTextHeight = glassTextViewHeight(for: textView)
    if abs(currentTextHeight - nextTextHeight) < 0.5 {
      // Glass divergence: normal typing within the same measured visual row
      // count does not change compose height.
      return
    }

    log.trace("update glass input height to \(nextTextHeight)")

    updateHeight(animate: animate)
  }

  private func contentHeight(for textView: NSTextView) -> CGFloat {
    ComposeTextEditor.measuredContentHeight(for: textView)
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }

    paragraphDirectionController.selectionDidChange()

    // Reset typing attributes when cursor moves to prevent mention style leakage
    textView.updateTypingAttributesIfNeeded()
    detectComposeCompletionsAtCursor(trigger: .selectionChange)
  }

  func textViewDidPressArrowDown(_ textView: NSTextView, event: NSEvent) -> Bool {
    guard shouldHandlePlainComposeArrow(textView, event: event) else { return false }

    if autocompleteMenu?.isVisible == true {
      return handleAutocompleteArrow(.next)
    }

    if commandCompletionMenu?.isVisible == true {
      commandCompletionMenu?.selectNext()
      return true
    }

    // If mention menu is visible, let it handle the arrow key
    if mentionCompletionMenu?.isVisible == true {
      mentionCompletionMenu?.selectNext()
      return true
    }

    return false // not handled
  }

  func textViewDidPressArrowLeft(_ textView: NSTextView, event: NSEvent) -> Bool {
    guard shouldHandlePlainComposeArrow(textView, event: event) else { return false }

    guard let autocompleteMenu,
          autocompleteMenu.isVisible,
          autocompleteMenu.isShowingEmojiPalette
    else {
      return false
    }

    return handleAutocompleteArrow(.previous)
  }

  func textViewDidPressArrowRight(_ textView: NSTextView, event: NSEvent) -> Bool {
    guard shouldHandlePlainComposeArrow(textView, event: event) else { return false }

    guard let autocompleteMenu,
          autocompleteMenu.isVisible,
          autocompleteMenu.isShowingEmojiPalette
    else {
      return false
    }

    return handleAutocompleteArrow(.next)
  }

  private func shouldHandlePlainComposeArrow(_ textView: NSTextView, event: NSEvent) -> Bool {
    guard !textView.hasMarkedText() else {
      dismissCompletionMenusForTextNavigation()
      return false
    }

    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard modifiers.isEmpty else {
      dismissCompletionMenusForTextNavigation()
      return false
    }

    return true
  }

  private func dismissCompletionMenusForTextNavigation() {
    hideMentionCompletion()
    hideCommandCompletion()
    hideAutocomplete()
  }

  private func handleAutocompleteArrow(_ direction: ComposeAutocompleteArrowDirection) -> Bool {
    guard let autocompleteMenu,
          autocompleteMenu.isVisible
    else {
      return false
    }
    guard autocompleteMenu.canSelectItems else { return true }

    if autocompleteMenu.isShowingEmojiPalette, isAtEmojiPaletteEdge(direction) {
      hideAutocomplete()
      return false
    }

    switch direction {
      case .previous:
        autocompleteViewModel.selectPrevious()
      case .next:
        autocompleteViewModel.selectNext()
    }

    return true
  }

  private func isAtEmojiPaletteEdge(_ direction: ComposeAutocompleteArrowDirection) -> Bool {
    let count = autocompleteViewModel.items.count
    guard count > 0 else { return true }

    switch direction {
      case .previous:
        return autocompleteViewModel.selectedIndex <= 0
      case .next:
        return autocompleteViewModel.selectedIndex >= count - 1
    }
  }

  func textViewDidPressTab(_ textView: NSTextView) -> Bool {
    if handleAutocompleteCommitKey() { return true }

    if commandCompletionMenu?.isVisible == true {
      commandCompletionMenu?.selectCurrentItem(sendAfterInsertion: false)
      return true
    }

    // If mention menu is visible, select current item
    if mentionCompletionMenu?.isVisible == true {
      mentionCompletionMenu?.selectCurrentItem()
      return true
    }

    return false // not handled
  }

  func textViewDidPressEscape(_ textView: NSTextView) -> Bool {
    if autocompleteCommitKeyAction != .ignore {
      hideAutocomplete(suppressCurrentMatch: true)
      return true
    }

    if commandCompletionMenu?.isVisible == true {
      hideCommandCompletion()
      return true
    }

    // If mention menu is visible, hide it
    if mentionCompletionMenu?.isVisible == true {
      hideMentionCompletion()
      return true
    }

    return false // not handled
  }

  private var autocompleteCommitKeyAction: ComposeAutocompleteCommitKeyAction {
    composeAutocompleteCommitKeyAction(
      match: autocompleteViewModel.match,
      loadState: autocompleteViewModel.loadState,
      isVisible: autocompleteMenu?.isVisible == true,
      canSelectItems: autocompleteMenu?.canSelectItems == true
    )
  }

  private func handleAutocompleteCommitKey() -> Bool {
    switch autocompleteCommitKeyAction {
      case .ignore:
        return false
      case .consume:
        return true
      case .select:
        _ = autocompleteMenu?.selectCurrentItem()
        return true
    }
  }

  func textViewDidChangeFormatting(_ textView: NSTextView) {
    persistDraftAfterProgrammaticChange()
  }

  func textView(_ textView: NSTextView, didDetectMentionWith query: String, at location: Int) {
    // This method is called from text change detection
    // Implementation will be in textDidChange
  }

  func textViewDidCancelMention(_ textView: NSTextView) {
    hideMentionCompletion()
    hideCommandCompletion()
    hideAutocomplete()
  }

  func textViewDidGainFocus(_ textView: NSTextView) {
    paragraphDirectionController.didGainFocus()
    if case .newThread = usage {
      setAccessoryBarExpanded(true)
    }
  }

  func textViewDidLoseFocus(_ textView: NSTextView) {
    DispatchQueue.main.async { [weak self, weak textView] in
      guard let self, let textView else { return }

      if window?.firstResponder === textView {
        return
      }

      if autocompleteMenuContainsFirstResponder() {
        focus()
        return
      }

      if firstResponderIsInsideCompose() {
        return
      }

      // Hide mention menu when text view loses focus
      hideMentionCompletion()
      hideCommandCompletion()
      hideAutocomplete()
      if case .newThread = usage, isEmpty, !hasAnyAttachments {
        setAccessoryBarExpanded(false)
      }
    }
  }

  private func firstResponderIsInsideCompose() -> Bool {
    guard let responderView = window?.firstResponder as? NSView else { return false }
    return responderView === self || responderView.isDescendant(of: self)
  }

  private func autocompleteMenuContainsFirstResponder() -> Bool {
    guard let menu = autocompleteMenu,
          menu.isVisible,
          let responderView = window?.firstResponder as? NSView
    else {
      return false
    }

    return responderView === menu || responderView.isDescendant(of: menu)
  }
}

// MARK: ComposeEmojiButtonDelegate

extension GlassComposeAppKit: ComposeEmojiButtonDelegate {
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveText text: String) {
    focus()
    textEditor.insertText(text)
  }

  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveSticker image: NSImage) {
    if case .chat = usage {
      sendSticker(image)
    } else {
      addImage(image)
    }
    focus()
  }
}

// MARK: ComposeMenuButtonDelegate

extension GlassComposeAppKit: ComposeMenuButtonDelegate {
  func composeMenuButtonDidRequestCommands(_ button: ComposeMenuButton) {
    showCommandsFromMenu()
  }

  func composeMenuButton(_ button: ComposeMenuButton, didSelectImage image: NSImage, url: URL) {
    handleImageDropOrPaste(image, url)
  }

  func composeMenuButton(_ button: ComposeMenuButton, didSelectVideo url: URL) {
    handleVideoDropOrPaste(url)
  }

  func composeMenuButton(_ button: ComposeMenuButton, didSelectFiles urls: [URL]) {
    handleFileDrop(urls)
  }

  func composeMenuButton(didCaptureImage image: NSImage) {
    handleImageDropOrPaste(image)
  }
}

// MARK: MentionCompletionMenuDelegate

extension GlassComposeAppKit: MentionCompletionMenuDelegate {
  func mentionMenu(_ menu: MentionCompletionMenu, didSelectItem item: MentionCompletionItem, withText text: String) {
    guard let mentionRange = currentMentionRange else { return }
    log.trace("mentionMenu didSelectItem: \(text)")

    let currentAttributedText = textEditor.attributedString
    let result = switch item {
      case let .user(user):
        mentionDetector.replaceMention(
          in: currentAttributedText,
          range: mentionRange.range,
          with: text,
          userId: user.userInfo.user.id,
          mentionAttributes: composeMentionAttributes,
          trailingAttributes: composeBaseTextAttributes
        )
      case let .group(group):
        mentionDetector.replaceGroupMention(
          in: currentAttributedText,
          range: mentionRange.range,
          with: text,
          groupId: group.id,
          mentionAttributes: composeMentionAttributes,
          trailingAttributes: composeBaseTextAttributes
        )
      case let .agent(agent):
        mentionDetector.replaceMention(
          in: currentAttributedText,
          range: mentionRange.range,
          with: text,
          userId: agent.botUserId,
          agentId: agent.id,
          mentionAttributes: composeMentionAttributes,
          trailingAttributes: composeBaseTextAttributes
        )
    }

    // Update attributed text and cursor position
    ignoreNextHeightChange = true
    textEditor.setAttributedString(result.newAttributedText)
    textEditor.textView.setSelectedRange(NSRange(location: result.newCursorPosition, length: 0))
    textEditor.textView.resetTypingAttributesToDefault()
    ignoreNextHeightChange = false

    // Hide the menu
    hideMentionCompletion()

    // Update height if needed
    updateHeightIfNeeded(for: textEditor.textView)
    persistDraftAfterProgrammaticChange()
  }

  func mentionMenuDidRequestClose(_ menu: MentionCompletionMenu) {
    hideMentionCompletion()
  }
}

extension GlassComposeAppKit: CommandCompletionMenuDelegate {
  func commandMenu(
    _ menu: CommandCompletionMenu,
    didSelectSuggestion suggestion: ComposeCommandSuggestion,
    sendAfterInsertion: Bool
  ) {
    guard let currentSlashCommandRange else { return }

    if case let .inline(command) = suggestion {
      hideCommandCompletion()
      if sendAfterInsertion {
        performInlineCommand(command.action)
      } else {
        // App commands are not inserted on Tab: leaving executable system text in compose could
        // later send it to a bot or the chat instead of running the local action.
        updateHeightIfNeeded(for: textEditor.textView)
      }
      return
    }

    guard case let .bot(botSuggestion) = suggestion else { return }

    let currentAttributedText = textEditor.attributedString
    let commandText = botSuggestion.insertionText.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = slashCommandDetector.replaceSlashCommand(
      in: currentAttributedText,
      range: currentSlashCommandRange.range,
      with: commandText,
      targetBotUserId: botSuggestion.botId
    )

    ignoreNextHeightChange = true
    textEditor.setAttributedString(result.newAttributedText)
    textEditor.textView.setSelectedRange(NSRange(location: result.newCursorPosition, length: 0))
    ignoreNextHeightChange = false

    hideCommandCompletion()

    if sendAfterInsertion {
      send()
    } else {
      updateHeightIfNeeded(for: textEditor.textView)
      persistDraftAfterProgrammaticChange()
    }
  }

  func commandMenuDidRequestClose(_ menu: CommandCompletionMenu) {
    hideCommandCompletion()
  }
}

extension GlassComposeAppKit: ComposeAutocompleteMenuDelegate {
  func autocompleteMenu(_ menu: ComposeAutocompleteMenu, didSelect item: ComposeAutocompleteItem) {
    guard let match = autocompleteViewModel.match else { return }

    switch item.payload {
      case let .thread(chatId, _, title):
        let result = if match.kind == .threadNumber,
                        let reference = item.threadReference
        {
          threadLinkDetector.replaceThreadNumberReference(
            in: textEditor.attributedString,
            range: match.range,
            with: reference,
            linkAttributes: composeThreadLinkAttributes,
            trailingAttributes: composeBaseTextAttributes
          )
        } else {
          threadLinkDetector.replaceThreadLink(
            in: textEditor.attributedString,
            range: match.range,
            with: title,
            chatId: chatId,
            linkAttributes: composeThreadLinkAttributes,
            trailingAttributes: composeBaseTextAttributes
          )
        }

        ignoreNextHeightChange = true
        textEditor.setAttributedString(result.newAttributedText)
        textEditor.textView.setSelectedRange(NSRange(location: result.newCursorPosition, length: 0))
        textEditor.textView.resetTypingAttributesToDefault()
        ignoreNextHeightChange = false

        hideAutocomplete()
        updateHeightIfNeeded(for: textEditor.textView)
        persistDraftAfterProgrammaticChange()

      case let .externalResource(resource):
        let result = ExternalResourceLinkEditing.replaceReference(
          in: textEditor.attributedString,
          range: match.range,
          with: resource,
          linkAttributes: composeThreadLinkAttributes,
          trailingAttributes: composeBaseTextAttributes
        )

        ignoreNextHeightChange = true
        textEditor.setAttributedString(result.newAttributedText)
        textEditor.textView.setSelectedRange(NSRange(location: result.newCursorPosition, length: 0))
        textEditor.textView.resetTypingAttributesToDefault()
        ignoreNextHeightChange = false

        hideAutocomplete()
        updateHeightIfNeeded(for: textEditor.textView)
        persistDraftAfterProgrammaticChange()

      case let .emoji(value, _):
        let preferredValue = AppSettings.shared.preferredEmojiSkinTone.applying(to: value)
        let result = emojiAutocompleteDetector.replaceEmojiAutocomplete(
          in: textEditor.attributedString,
          range: match.range,
          with: preferredValue
        )

        ignoreNextHeightChange = true
        textEditor.setAttributedString(result.attributedText)
        textEditor.textView.setSelectedRange(NSRange(location: result.cursorPosition, length: 0))
        ignoreNextHeightChange = false

        hideAutocomplete()
        updateHeightIfNeeded(for: textEditor.textView)
        persistDraftAfterProgrammaticChange()

      case .mention, .command, .inlineCommand:
        assertionFailure("iOS-only autocomplete payload reached the glass macOS composer")
    }
  }

  private var composeThreadLinkAttributes: [NSAttributedString.Key: Any] {
    var attributes = composeBaseTextAttributes
    attributes[.foregroundColor] = ComposeTextEditor.linkColor
    return attributes
  }

  private var composeMentionAttributes: [NSAttributedString.Key: Any] {
    var attributes = composeBaseTextAttributes
    attributes[.foregroundColor] = ComposeTextEditor.linkColor
    return attributes
  }

  private var composeBaseTextAttributes: [NSAttributedString.Key: Any] {
    textEditor.textView.defaultTypingAttributes
  }

  func autocompleteMenuDidRequestClose(_ menu: ComposeAutocompleteMenu) {
    hideAutocomplete(suppressCurrentMatch: true)
  }
}

// MARK: - Rich text loading

extension GlassComposeAppKit {
  func toAttributedString(text: String, entities: MessageEntities?) -> NSAttributedString {
    ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: ComposeTextEditor.font,
        primaryColor: ComposeTextEditor.textColor,
        linkColor: ComposeTextEditor.linkColor,
        convertMentionsToLink: false
      )
    )
  }

  func setMessage(text: String, entities: MessageEntities?) {
    // Convert to attributed string
    let attributedString = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: ComposeTextEditor.font,
        primaryColor: ComposeTextEditor.textColor,
        linkColor: ComposeTextEditor.linkColor,
        convertMentionsToLink: false
      )
    )

    setAttributedString(attributedString)
  }

  func setAttributedString(_ attributedString: NSAttributedString) {
    // Set as compose text
    textEditor.replaceAttributedString(attributedString)
    paragraphDirectionController.refreshAllParagraphDirections()
    textEditor.showPlaceholder(text.isEmpty)

    // Measure new height
    updateContentHeight(for: textEditor.textView)

    // Update compose height
    updateHeight(animate: false)

    updateSendButtonIfNeeded()
  }
}

// MARK: - Draft

extension GlassComposeAppKit {
  private func persistDraftAfterProgrammaticChange() {
    updateSendButtonIfNeeded()
    switch usage {
      case .chat:
        saveDraft()
      case .newThread:
        notifyNewThreadDraftChanged()
    }
  }

  /// Loads draft and if nothing found returns false
  func loadDraft() -> Bool {
    guard let draft = drafts2.load(peer: peerId, legacyDraftMessage: dialog?.draftMessage),
          !draft.isEmpty
    else {
      return false
    }

    // Convert to attributed string. Most drafts are plain text, so avoid entity
    // parsing work when protobuf entities are not present.
    let attributedString: NSAttributedString = if let entities = draft.entities {
      toAttributedString(
        text: draft.text,
        entities: entities
      )
    } else {
      textEditor.createAttributedString(draft.text)
    }

    // `didLayout()` is called after layout in normal flow. Only force layout
    // when width isn't resolved yet.
    if textEditor.bounds.width <= 1 {
      layoutSubtreeIfNeeded()
    }

    // Set as compose text
    setAttributedString(attributedString)
    renderDraftAttachments(draft.attachments)

    return true
  }

  @discardableResult
  private func saveDraft() -> Int64 {
    let revision = updateDraftTextFromEditor()
    saveDraftEntities(forRevision: revision)
    return revision
  }

  private func clearDraft() {
    clearDraft(flush: false)
  }

  private func clearDraft(flush: Bool) {
    draftEntitySaveTask?.cancel()
    draftEntitySaveTask = nil
    drafts2.clear(peer: peerId)
    if flush {
      drafts2.flushBlocking()
    }
  }

  private func requestImmediateDraftPersistenceIfNeeded() {
    guard didRequestFinalDraftPersistence == false else { return }
    didRequestFinalDraftPersistence = true

    draftEntitySaveTask?.cancel()
    draftEntitySaveTask = nil

    saveDraft()
    drafts2.flushBlocking()
  }

  /// Triggers save with a 3s delay which cancels previous Task thus creating a basic debounced
  /// entity extraction to be used on textDidChange.
  private func saveDraftWithDebounce() {
    let revision = updateDraftTextFromEditor()
    scheduleDraftEntitySave(forRevision: revision)
  }

  @discardableResult
  private func updateDraftTextFromEditor() -> Int64 {
    let text = textEditor.textView.string.replacingOccurrences(of: Self.attachmentMarker, with: "")
    return drafts2.updateText(peer: peerId, text: text)
  }

  private func scheduleDraftEntitySave(forRevision revision: Int64) {
    draftEntitySaveTask?.cancel()
    draftEntitySaveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled else { return }
      saveDraftEntities(forRevision: revision)
    }
  }

  private func saveDraftEntities(forRevision revision: Int64) {
    let (rawText, entities) = ProcessEntities.fromAttributedString(
      textEditor.attributedString,
      parseMarkdown: false,
      threadLinkSpaceId: chat?.spaceId
    )
    let text = rawText.replacingOccurrences(of: Self.attachmentMarker, with: "")
    let normalizedEntities: MessageEntities? = rawText == text ? Drafts2.normalizedEntities(entities) : nil
    drafts2.updateEntities(peer: peerId, entities: normalizedEntities, forRevision: revision)
  }

  private func renderDraftAttachments(_ draftAttachments: [Drafts2Attachment]) {
    guard !draftAttachments.isEmpty else { return }

    attachmentItems.removeAll()
    attachments.clearViews()
    for attachment in draftAttachments {
      renderDraftAttachment(attachment)
    }

    updateHeight(animate: false)
    updateSendButtonIfNeeded()
  }

  private func handleDraftAttachmentResult(_ result: Drafts2AttachmentResult) {
    switch result {
      case let .pending(pendingId):
        if !attachments.containsAttachment(id: pendingId) {
          attachments.addPendingAttachment(id: pendingId)
          updateHeight(animate: true)
        }
        updateSendButtonIfNeeded()
        notifyNewThreadDraftChanged()
      case let .success(pendingId, attachment):
        removeDraftAttachmentPlaceholder(id: pendingId)
        let ownsAttachment = switch usage {
          case .chat:
            drafts2.load(peer: peerId)?.attachments.contains(where: { $0.id == attachment.id }) == true
          case let .newThread(context):
            context.attachmentStore.contains(id: attachment.id)
        }
        guard ownsAttachment else {
          updateSendButtonIfNeeded()
          return
        }
        renderDraftAttachment(attachment)
        updateHeight(animate: true)
        updateSendButtonIfNeeded()
        notifyNewThreadDraftChanged()
      case let .failure(pendingId, message):
        removeDraftAttachmentPlaceholder(id: pendingId)
        log.error("Failed to save draft attachment: \(message)")
        ToastCenter.shared.showError("Couldn’t add attachment as media or a file.")
        updateHeight(animate: true)
        updateSendButtonIfNeeded()
        notifyNewThreadDraftChanged()
      case let .cancelled(pendingId):
        removeDraftAttachmentPlaceholder(id: pendingId)
        updateHeight(animate: true)
        updateSendButtonIfNeeded()
        notifyNewThreadDraftChanged()
    }
  }

  private func renderDraftAttachment(_ attachment: Drafts2Attachment) {
    switch attachment.media {
      case let .photo(photoInfo):
        guard let image = loadThumbnail(from: photoInfo) else {
          log.warning("Unable to render draft photo attachment without local thumbnail")
          return
        }
        attachmentItems[attachment.id] = attachment.media
        attachments.addImageView(image, id: attachment.id)
      case let .video(videoInfo):
        attachmentItems[attachment.id] = attachment.media
        attachments.addVideoView(videoInfo, id: attachment.id)
      case let .document(documentInfo):
        attachmentItems[attachment.id] = attachment.media
        attachments.addDocumentView(documentInfo, id: attachment.id)
      case let .voice(voice):
        guard voiceViewModel.loadDraftVoice(voice) else {
          log.warning("Unable to restore draft voice attachment")
          return
        }
        attachmentItems[attachment.id] = attachment.media
        updateVoiceAvailability(phase: .review)
    }
  }

  private func removeDraftAttachmentPlaceholder(id: String) {
    attachments.removeImageView(id: id)
    attachments.removeVideoView(id: id)
    attachments.removeDocumentView(id: id)
  }

  private func restorePendingDraftAttachmentPlaceholders() {
    for pendingId in drafts2.pendingAttachmentIDs(peer: peerId) {
      handleDraftAttachmentResult(.pending(pendingId: pendingId))
    }
  }
}

extension GlassComposeAppKit: ComposeImplementation, ComposeAttachmentOwner {
  var view: NSView {
    self
  }

  func hostWillMove(toSuperview newSuperview: NSView?) {
    guard case .chat = usage else { return }
    if newSuperview == nil {
      cancelTranscriptionForRemoval()
      requestImmediateDraftPersistenceIfNeeded()
    } else {
      didRequestFinalDraftPersistence = false
    }
  }
}
