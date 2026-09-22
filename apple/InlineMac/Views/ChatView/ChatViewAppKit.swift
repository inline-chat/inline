import AppKit
import Combine
import Cocoa
import InlineKit
import InlineMacUI
import InlineUI
import Logger
import Nuke
import RealtimeV2
import SwiftUI
import os.signpost

enum ChatViewError: Error {
  case failedToLoad
}

struct ChatViewAppearance {
  enum SurfaceStyle {
    case content
    case replyThread

    var backgroundColor: NSColor {
      switch self {
      case .content:
        Theme.windowContentBackgroundColor
      case .replyThread:
        Theme.replyThreadPaneBackgroundColor
      }
    }
  }

  let surfaceStyle: SurfaceStyle
  let additionalTopContentInset: CGFloat

  var surfaceBackgroundColor: NSColor {
    surfaceStyle.backgroundColor
  }

  init(
    surfaceStyle: SurfaceStyle,
    additionalTopContentInset: CGFloat = 0
  ) {
    self.surfaceStyle = surfaceStyle
    self.additionalTopContentInset = additionalTopContentInset.isFinite
      ? max(0, additionalTopContentInset)
      : 0
  }

  static let standard = ChatViewAppearance(
    surfaceStyle: .content,
    additionalTopContentInset: 0
  )
}

class ChatViewAppKit: NSViewController {
  let peerId: Peer
  let dependencies: AppDependencies
  private let toolbarState: ChatToolbarState?
  private let onDialogChange: (@MainActor (Dialog?) -> Void)?
  private let appearance: ChatViewAppearance
  private var viewModel: FullChatViewModel
  private var preparedPayload: PreparedChatPayload?
  private let usesExperimentalMessageList: Bool
  private var experimentalPreparationTask: Task<Void, Never>?

  private var dialog: Dialog? {
    viewModel.chatItem?.dialog
  }

  private enum State {
    case initial(Chat?)
    case loading
    case loaded(Chat)
    case error(Error)
  }

  private var state: State {
    didSet { updateState() }
  }

  // Child controllers
  private var messageListVC: (any ChatMessageListController)?
  private var compose: ComposeAppKit?
  private var messageSelectionCoordinator: MessageSelectionCoordinator?
  private var spinnerVC: NSHostingController<SpinnerView>?
  private var errorVC: NSHostingController<ChatLoadErrorView>?
  private var appDidBecomeActiveObserver: NSObjectProtocol?
  private var mediaSendFailedObserver: NSObjectProtocol?
  private var chatItemCancellable: AnyCancellable?
  private var fetchChatTask: Task<Void, Never>?
  private var isDisposed = false
  private var didStartDeferredObservation = false
  private var didScrollToInitialTarget = false

  private var didInitialRefetch = false
  private let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  private var viewDidLayoutCount = 0

  init(
    peerId: Peer,
    chat: Chat? = nil,
    preparedPayload: PreparedChatPayload? = nil,
    dependencies: AppDependencies,
    appearance: ChatViewAppearance = .standard,
    toolbarState: ChatToolbarState? = nil,
    onDialogChange: (@MainActor (Dialog?) -> Void)? = nil
  ) {
    self.peerId = peerId
    self.dependencies = dependencies
    self.appearance = appearance
    self.toolbarState = toolbarState
    self.onDialogChange = onDialogChange
    self.preparedPayload = preparedPayload
    usesExperimentalMessageList = ExperimentalMessageListFeature.isAvailable && (
      preparedPayload.map { $0.experimentalPosition != nil } ?? ExperimentalMessageListFeature.isEnabled
    )
    viewModel = FullChatViewModel(
      db: dependencies.database,
      peer: peerId,
      initialChatItem: preparedPayload?.chatItem,
      startObservation: preparedPayload == nil
    )
    state = .initial(viewModel.chat)
    super.init(nibName: nil, bundle: nil)

    updateDialog(from: viewModel.chatItem)
    observeChatItem()

    if preparedPayload == nil {
      // Refetch immediately when no prepared payload exists.
      viewModel.refetchChatView()
    }

    appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, !isDisposed else { return }
      viewModel.refetchChatView()
    }

    mediaSendFailedObserver = NotificationCenter.default.addObserver(
      forName: .mediaSendFailed,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
            !isDisposed,
            let chatId = notification.userInfo?["chatId"] as? Int64,
            chatId == self.viewModel.chat?.id
      else { return }

      let message = notification.userInfo?["message"] as? String ?? "Couldn't send attachment."
      Task { @MainActor in
        ToastCenter.shared.showError(message)
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let signpostID = OSSignpostID(log: signpostLog)
    os_signpost(
      .begin,
      log: signpostLog,
      name: "ChatViewLoadView",
      signpostID: signpostID,
      "%{public}s",
      String(describing: peerId)
    )
    defer {
      os_signpost(.end, log: signpostLog, name: "ChatViewLoadView", signpostID: signpostID)
    }

    let rootView = ChatDropView()
    rootView.surfaceStyle = appearance.surfaceStyle
    view = rootView
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true

    transitionFromInitialState()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupDragAndDrop()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    startDeferredObservationIfNeeded()
  }

  override func viewDidLayout() {
    viewDidLayoutCount += 1
    let shouldSignpost = viewDidLayoutCount <= 20

    guard shouldSignpost else {
      super.viewDidLayout()
      compose?.didLayout()
      return
    }

    let signpostID = OSSignpostID(log: signpostLog)
    let count = viewDidLayoutCount
    os_signpost(
      .begin,
      log: signpostLog,
      name: "ChatViewDidLayout",
      signpostID: signpostID,
      "%{public}s",
      "count=\(count)"
    )
    defer {
      os_signpost(.end, log: signpostLog, name: "ChatViewDidLayout", signpostID: signpostID)
    }

    super.viewDidLayout()
    compose?.didLayout()
  }

  private func transitionFromInitialState() {
    guard !isDisposed else { return }
    switch state {
      case let .initial(chat):
        if let chat = chat ?? viewModel.chat {
          state = .loaded(chat)
        } else {
          state = .loading
          fetchChat()
        }
      default: break
    }
  }

  private func startDeferredObservationIfNeeded() {
    guard preparedPayload != nil, !didStartDeferredObservation, !isDisposed else { return }
    didStartDeferredObservation = true
    viewModel.startChatObservationIfNeeded()
    viewModel.refetchChatView()
  }

  private func updateState() {
    guard !isDisposed else { return }
    clearCurrentViews()

    switch state {
      case .initial:
        break // Handled in transitionFromInitialState
      case .loading:
        showSpinner()
      case let .loaded(chat):
        setupChatComponents(chat: chat)
      case let .error(error):
        showError(error: error)
        dependencies.nav2?.endChatNavigationSignpost(peer: peerId, reason: "error")
        dependencies.nav3?.endChatNavigationSignpost(peer: peerId, reason: "error")
    }
  }

  // MARK: - Spinner

  private func showSpinner() {
    // Create SwiftUI spinner view
    let spinnerView = SpinnerView()
    let hostingController = NSHostingController(rootView: spinnerView)

    // Add as child view controller
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      hostingController.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    spinnerVC = hostingController
  }

  private func showError(error _: Error) {
    let errorView = ChatLoadErrorView(
      retryAction: { [weak self] in
        self?.state = .loading
        self?.fetchChat()
      }
    )

    let hostingController = NSHostingController(rootView: errorView)

    // Add as child view controller
    addChild(hostingController)
    view.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      hostingController.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    errorVC = hostingController
  }

  private func observeChatItem() {
    chatItemCancellable = viewModel.$chatItem
      .dropFirst()
      .sink { [weak self] item in
        Task { @MainActor [weak self] in
          guard let self, !isDisposed else { return }
          updateDialog(from: item)
          compose?.setPeerUser(item?.user)
          guard let chat = item?.chat else { return }
          showLoadedChat(chat)
        }
      }
  }

  private func updateDialog(from item: SpaceChatItem?) {
    let dialog = item?.dialog
    messageListVC?.setCollapsedMaxId(dialog?.collapsedMaxId)
    guard let onDialogChange else { return }
    Task { @MainActor [weak self] in
      guard let self, !isDisposed else { return }
      onDialogChange(dialog)
    }
  }

  private func showLoadedChat(_ chat: Chat) {
    guard !isDisposed else { return }
    guard isViewLoaded else { return }
    if case let .loaded(current) = state, current.id == chat.id {
      return
    }
    state = .loaded(chat)
  }

  private func setupChatComponents(chat: Chat) {
    if usesExperimentalMessageList, preparedPayload == nil {
      guard experimentalPreparationTask == nil else { return }
      if spinnerVC == nil { showSpinner() }
      experimentalPreparationTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { experimentalPreparationTask = nil }
        do {
          let payload = try await ChatOpenPreloader.shared.prepare(
            peer: peerId, database: dependencies.database, experimentalMessageList: true
          )
          guard !Task.isCancelled, !isDisposed else { return }
          preparedPayload = payload
          spinnerVC?.view.removeFromSuperview()
          spinnerVC?.removeFromParent()
          spinnerVC = nil
          setupChatComponents(chat: chat)
        } catch is CancellationError {
          return
        } catch {
          guard !isDisposed else { return }
          state = .error(error)
        }
      }
      return
    }
    let componentsSignpostID = OSSignpostID(log: signpostLog)
    os_signpost(
      .begin,
      log: signpostLog,
      name: "ChatComponentsSetup",
      signpostID: componentsSignpostID,
      "%{public}s",
      String(describing: peerId)
    )
    defer {
      os_signpost(.end, log: signpostLog, name: "ChatComponentsSetup", signpostID: componentsSignpostID)
    }

    // Message List
    let messageListVC_: any ChatMessageListController
    do {
      let signpostID = OSSignpostID(log: signpostLog)
      os_signpost(
        .begin,
        log: signpostLog,
        name: "MessageListSetup",
        signpostID: signpostID,
        "%{public}s",
        preparedPayload == nil ? "cold" : "prepared"
      )
      defer {
        os_signpost(.end, log: signpostLog, name: "MessageListSetup", signpostID: signpostID)
      }

      if usesExperimentalMessageList {
        messageListVC_ = ExperimentalMessageListAppKit(
          dependencies: dependencies,
          peerId: peerId,
          chat: chat,
          showUnreadAfter: unreadBoundaryAtOpen(),
          initialState: preparedPayload?.messagesInitialState,
          initialPosition: preparedPayload?.experimentalPosition ?? .latest,
          requestedMessageID: preparedPayload?.experimentalRequestedMessageID,
          collapsedMaxId: dialog?.collapsedMaxId,
          initialPinnedMessage: preparedPayload?.pinnedMessage,
          surfaceStyle: appearance.surfaceStyle,
          additionalTopContentInset: appearance.additionalTopContentInset
        )
      } else {
        messageListVC_ = MessageListAppKit(
          dependencies: dependencies,
          peerId: peerId,
          chat: chat,
          showUnreadAfter: unreadBoundaryAtOpen(),
          initialState: preparedPayload?.messagesInitialState,
          collapsedMaxId: dialog?.collapsedMaxId,
          initialPinnedMessage: preparedPayload?.pinnedMessage,
          surfaceStyle: appearance.surfaceStyle,
          additionalTopContentInset: appearance.additionalTopContentInset
        )
      }
    }
    addChild(messageListVC_)
    view.addSubview(messageListVC_.view)
    messageListVC_.view.translatesAutoresizingMaskIntoConstraints = false
    messageListVC_.setMaximumContentWidth(ChatLayoutMetrics.maximumWidth)

    messageListVC = messageListVC_

    // Compose
    let compose: ComposeAppKit
    do {
      let signpostID = OSSignpostID(log: signpostLog)
      os_signpost(.begin, log: signpostLog, name: "ComposeSetup", signpostID: signpostID)
      defer { os_signpost(.end, log: signpostLog, name: "ComposeSetup", signpostID: signpostID) }

      compose = ComposeAppKit(
        peerId: peerId,
        messageList: messageListVC!,
        chat: chat,
        peerUser: viewModel.peerUser,
        dependencies: dependencies,
        toolbarState: toolbarState,
        parentChatView: self,
        dialog: dialog,
        surfaceStyle: appearance.surfaceStyle
      )
    }
    view.addSubview(compose)
    compose.translatesAutoresizingMaskIntoConstraints = false
    self.compose = compose
    messageSelectionCoordinator = MessageSelectionCoordinator(
      list: messageListVC_, compose: compose, host: view, dependencies: dependencies
    )

    // Layout
    do {
      let signpostID = OSSignpostID(log: signpostLog)
      os_signpost(.begin, log: signpostLog, name: "ChatConstraintsSetup", signpostID: signpostID)
      defer { os_signpost(.end, log: signpostLog, name: "ChatConstraintsSetup", signpostID: signpostID) }

      NSLayoutConstraint.activate([
        // messageList
        messageListVC!.view.topAnchor.constraint(equalTo: view.topAnchor),
        messageListVC!.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        messageListVC!.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        messageListVC!.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

        // Share the message viewport, including space reserved for persistent scrollbars.
        compose.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        compose.leadingAnchor.constraint(equalTo: messageListVC_.messageColumnGuide.leadingAnchor),
        compose.trailingAnchor.constraint(equalTo: messageListVC_.messageColumnGuide.trailingAnchor),
      ])
    }

    scheduleInitialTargetScrollIfNeeded(chat: chat)
  }

  private func scheduleInitialTargetScrollIfNeeded(chat: Chat) {
    guard !usesExperimentalMessageList else { return }
    guard !didScrollToInitialTarget else { return }
    guard let targetMessageId = preparedPayload?.targetMessageId else { return }
    didScrollToInitialTarget = true

    DispatchQueue.main.async { [weak self] in
      guard let self, !isDisposed else { return }
      ChatsManager
        .get(for: peerId, chatId: chat.id)
        .scrollTo(msgId: targetMessageId, reason: .search)
    }
  }

  private func unreadBoundaryAtOpen() -> Int64? {
    let openDialog = preparedPayload?.chatItem?.dialog ?? dialog
    guard let openDialog else { return nil }

    let hasUnread = (openDialog.unreadCount ?? 0) > 0
    guard hasUnread else { return nil }

    return openDialog.readInboxMaxId
  }

  private func fetchChat() {
    fetchChatTask?.cancel()
    fetchChatTask = Task { [weak self] in
      guard let self, !isDisposed else { return }
      do {
        if let chat = try await viewModel.ensureChat() {
          await MainActor.run {
            guard !Task.isCancelled, !self.isDisposed else { return }
            self.showLoadedChat(chat)
          }
        } else {
          await MainActor.run {
            guard !Task.isCancelled, !self.isDisposed else { return }
            self.showChatLoadErrorIfDefinitive(ChatViewError.failedToLoad)
          }
        }
      } catch {
        await MainActor.run {
          guard !Task.isCancelled, !self.isDisposed else { return }
          self.showChatLoadErrorIfDefinitive(error)
        }
      }
    }
  }

  private func showChatLoadErrorIfDefinitive(_ error: Error) {
    guard isDefinitiveChatLoadError(error) else {
      Log.shared.warning("Chat cache miss is still loading for \(peerId)")
      return
    }
    if case .loaded = state {
      return
    }
    state = .error(error)
  }

  private func isDefinitiveChatLoadError(_ error: Error) -> Bool {
    guard let error = error as? TransactionError else {
      return true
    }

    switch error {
      case let .rpcError(rpcError):
        switch rpcError.errorCode {
          case .peerIDInvalid, .chatIDInvalid, .userIDInvalid, .spaceIDInvalid:
            return true
          default:
            return false
        }
      case .invalid, .persistenceFailed:
        return true
      case .timeout, .commitOutcomeUnknownAfterReconnect, .rejectedBeforeExecution, .dependencyFailed:
        return false
    }
  }

  private func clearCurrentViews() {
    messageSelectionCoordinator?.dispose()
    messageSelectionCoordinator = nil
    // Remove any non-controller views
    if let messageListVC {
      messageListVC.dispose()
      messageListVC.view.removeFromSuperview()
      messageListVC.removeFromParent()
    }

    // Remove child view controllers properly
    for child in children {
      child.view.removeFromSuperview()
      child.removeFromParent()
    }

    compose?.messageList = nil
    compose?.removeFromSuperview()

    // Reset all references
    spinnerVC = nil
    errorVC = nil
    messageListVC = nil
    compose = nil
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
  }

  func dispose() {
    experimentalPreparationTask?.cancel()
    experimentalPreparationTask = nil
    guard !isDisposed else { return }
    isDisposed = true
    fetchChatTask?.cancel()
    fetchChatTask = nil
    chatItemCancellable?.cancel()
    chatItemCancellable = nil
    viewModel.dispose()
    removeObservers()
    clearCurrentViews()
  }

  deinit {
    dispose()
  }

  private func removeObservers() {
    if let appDidBecomeActiveObserver {
      NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
      self.appDidBecomeActiveObserver = nil
    }
    if let mediaSendFailedObserver {
      NotificationCenter.default.removeObserver(mediaSendFailedObserver)
      self.mediaSendFailedObserver = nil
    }
  }

  // MARK: - Drag and Drop

  private func setupDragAndDrop() {
    guard let dropView = view as? ChatDropView else { return }
    dropView.dropHandler = { [weak self] sender in
      self?.compose?.handleAttachments(from: sender.draggingPasteboard) ?? false
    }
  }

  // MARK: - Helper Methods

  private func loadImage(from url: URL) async -> NSImage? {
    do {
      // Create a request with proper options
      let request = ImageRequest(
        url: url,
        processors: [.resize(width: 1_280)], // Resize to reasonable size
        priority: .normal,
        options: []
      )

      // Try to get image from pipeline
      let response = try await ImagePipeline.shared.image(for: request)
      return response
    } catch {
      Log.shared.error("Failed to load image from URL: \(error.localizedDescription)")
      return nil
    }
  }
}
