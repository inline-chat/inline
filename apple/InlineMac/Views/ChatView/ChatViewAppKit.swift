import AppKit
import Combine
import Cocoa
import InlineKit
import InlineUI
import Logger
import Nuke
import RealtimeV2
import SwiftUI
import os.signpost

enum ChatViewError: Error {
  case failedToLoad
}

class ChatViewAppKit: NSViewController {
  let peerId: Peer
  let dependencies: AppDependencies
  private var viewModel: FullChatViewModel
  private let preparedPayload: PreparedChatPayload?

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
  private var messageListVC: MessageListAppKit?
  private var compose: ComposeAppKit?
  private var spinnerVC: NSHostingController<SpinnerView>?
  private var errorVC: NSHostingController<ErrorView>?
  private var pendingDropObserver: NSObjectProtocol?
  private var appDidBecomeActiveObserver: NSObjectProtocol?
  private var mediaSendFailedObserver: NSObjectProtocol?
  private var chatItemCancellable: AnyCancellable?
  private var fetchChatTask: Task<Void, Never>?
  private var isDisposed = false
  private var didStartDeferredObservation = false

  private var didInitialRefetch = false
  private let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  private var viewDidLayoutCount = 0

  init(
    peerId: Peer,
    chat: Chat? = nil,
    preparedPayload: PreparedChatPayload? = nil,
    dependencies: AppDependencies
  ) {
    self.peerId = peerId
    self.dependencies = dependencies
    self.preparedPayload = preparedPayload
    viewModel = FullChatViewModel(
      db: dependencies.database,
      peer: peerId,
      initialChatItem: preparedPayload?.chatItem,
      startObservation: preparedPayload == nil
    )
    state = .initial(viewModel.chat)
    super.init(nibName: nil, bundle: nil)

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

    view = ChatDropView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true

    transitionFromInitialState()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupDragAndDrop()
    setupPendingDropObserver()
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
        dependencies.nav2?.endChatNavigationSignpost(peer: peerId, reason: "loaded")
        dependencies.nav3?.endChatNavigationSignpost(peer: peerId, reason: "loaded")
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

  private func showError(error: Error) {
    // Create SwiftUI error view with retry action
    let errorView = ErrorView(
      errorMessage: error.localizedDescription,
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
      .compactMap { $0?.chat }
      .sink { [weak self] chat in
        Task { @MainActor [weak self] in
          self?.showLoadedChat(chat)
        }
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
    let messageListVC_: MessageListAppKit
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

      messageListVC_ = MessageListAppKit(
        dependencies: dependencies,
        peerId: peerId,
        chat: chat,
        showUnreadAfter: unreadBoundaryAtOpen(),
        initialState: preparedPayload?.messagesInitialState,
        initialPinnedMessage: preparedPayload?.pinnedMessage
      )
    }
    addChild(messageListVC_)
    view.addSubview(messageListVC_.view)
    messageListVC_.view.translatesAutoresizingMaskIntoConstraints = false

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
        dependencies: dependencies,
        parentChatView: self,
        dialog: dialog
      )
    }
    view.addSubview(compose)
    compose.translatesAutoresizingMaskIntoConstraints = false
    self.compose = compose

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

        // compose
        compose.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        compose.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        compose.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
    }

    consumePendingDropAttachmentsIfPossible()
  }

  private func unreadBoundaryAtOpen() -> Int64? {
    let openDialog = preparedPayload?.chatItem?.dialog ?? dialog
    guard let openDialog else { return nil }

    let hasUnread = (openDialog.unreadCount ?? 0) > 0
    guard hasUnread else { return nil }

    return openDialog.readInboxMaxId ?? 0
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
          case .peerIDInvalid, .chatIDInvalid, .userIDInvalid:
            return true
          default:
            return false
        }
      case .invalid:
        return true
      case .timeout, .ackedButNoResultAfterReconnect, .dependencyFailed:
        return false
    }
  }

  private func clearCurrentViews() {
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
    if let pendingDropObserver {
      NotificationCenter.default.removeObserver(pendingDropObserver)
      self.pendingDropObserver = nil
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
      self?.handleAttachments(from: sender.draggingPasteboard) ?? false
    }
  }

  private func setupPendingDropObserver() {
    pendingDropObserver = NotificationCenter.default.addObserver(
      forName: PendingDropAttachments.didUpdateNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      guard let peer = notification.userInfo?["peerId"] as? Peer, peer == self.peerId else { return }
      self.consumePendingDropAttachmentsIfPossible()
    }
  }

  private func consumePendingDropAttachmentsIfPossible() {
    guard let compose else { return }
    let attachments = PendingDropAttachments.shared.consume(peerId: peerId)
    guard attachments.isEmpty == false else { return }
    compose.handlePasteboardAttachments(attachments)
  }

  private func handleAttachments(from pasteboard: NSPasteboard) -> Bool {
    Log.shared.debug("Handling attachments from pasteboard")

    let attachments = InlinePasteboard.findAttachments(from: pasteboard)

    for attachment in attachments {
      switch attachment {
        case let .image(image, _):
          handleDroppedImage(image)
        case let .video(url, _):
          handleDroppedVideo(url)
        case let .file(url, _):
          handleDroppedFile(url)
        case let .text(text):
          handleDroppedText(text)
      }
    }

    if attachments.isEmpty {
      Log.shared.debug("No attachments found in pasteboard")
      return false
    } else {
      return true
    }
  }

  // FILE DROPPED
  private func handleDroppedFile(_ url: URL) {
    compose?.handleFileDrop([url])
  }

  private func handleDroppedText(_ text: String) {
    compose?.handleTextDropOrPaste(text)
  }

  private func handleDroppedVideo(_ url: URL) {
    compose?.handleFileDrop([url])
  }

  // IMAGE DROPPED
  private func handleDroppedImage(_ image: NSImage) {
    compose?.handleImageDropOrPaste(image)
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
