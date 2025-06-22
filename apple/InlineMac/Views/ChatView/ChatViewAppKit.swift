import AppKit
import Cocoa
import Combine
import InlineKit
import InlineUI
import Logger
import Nuke
import SwiftUI

enum ChatViewError: Error {
  case failedToLoad
}

class ChatViewAppKit: NSViewController {
  let peerId: Peer
  let dependencies: AppDependencies
  private var viewModel: FullChatViewModel

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

  private var didInitialRefetch = false

  init(peerId: Peer, chat: Chat? = nil, dependencies: AppDependencies) {
    self.peerId = peerId
    self.dependencies = dependencies
    viewModel = FullChatViewModel(db: dependencies.database, peer: peerId)
    state = .initial(viewModel.chat)
    super.init(nibName: nil, bundle: nil)

    // Refetch
    viewModel.refetchChatView()

    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.viewModel.refetchChatView()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    view = ChatDropView()
    view.wantsLayer = true

    transitionFromInitialState()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupDragAndDrop()
  }

  private var loadedDraft = false

  override func viewDidLayout() {
    super.viewDidLayout()
    if !loadedDraft {
      compose?.loadDraft()
      loadedDraft = true
    }
  }

  private func transitionFromInitialState() {
    switch state {
      case let .initial(chat):
        if let chat {
          state = .loaded(chat)
        } else {
          state = .loading
          fetchChat()
        }
      default: break
    }
  }

  private func updateState() {
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

  private func setupChatComponents(chat: Chat) {
    // Message List
    let messageListVC_ = MessageListAppKit(dependencies: dependencies, peerId: peerId, chat: chat)
    addChild(messageListVC_)
    view.addSubview(messageListVC_.view)
    messageListVC_.view.translatesAutoresizingMaskIntoConstraints = false

    messageListVC = messageListVC_

    // Compose
    let compose = ComposeAppKit(
      peerId: peerId,
      messageList: messageListVC!,
      chat: chat,
      dependencies: dependencies,
      parentChatView: self,
      dialog: dialog
    )
    view.addSubview(compose)
    compose.translatesAutoresizingMaskIntoConstraints = false
    self.compose = compose

    // Layout
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

  private func fetchChat() {
    Task {
      do {
        if let chat = try? await viewModel.ensureChat() {
          await MainActor.run {
            state = .loaded(chat)
          }
        } else {
          await MainActor.run {
            state = .error(ChatViewError.failedToLoad)
          }
        }
      } catch {
        await MainActor.run {
          state = .error(error)
        }
      }
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
    clearCurrentViews()
  }

  deinit {
    clearCurrentViews()

    // Remove observer
    NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)

    // Remove window check since cleanup should have happened in viewWillDisappear
    Log.shared.debug("🗑️ Deinit: \(type(of: self)) - \(self)")
  }

  // MARK: - Drag and Drop

  private func setupDragAndDrop() {
    guard let dropView = view as? ChatDropView else { return }
    dropView.dropHandler = { [weak self] sender in
      self?.handleAttachments(from: sender.draggingPasteboard) ?? false
    }
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
