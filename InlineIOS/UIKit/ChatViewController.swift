import InlineKit
import SwiftUI
import UIKit

// MARK: - Chat View Controller

final class ChatViewController: UIViewController {
  private let messagesHostingController: UIHostingController<MessagesCollectionView>
  private let composeHostingController: UIHostingController<ComposeView>
  private let peer: Peer
  private let fullChatViewModel: FullChatViewModel
  @State private var messageText: String = ""

  init(peer: Peer) {
    self.peer = peer
    self.fullChatViewModel = FullChatViewModel(db: AppDatabase.shared, peer: peer)

    // Initialize SwiftUI views in hosting controllers
    self.messagesHostingController = UIHostingController(
      rootView: MessagesCollectionView(fullMessages: [])
    )
    self.composeHostingController = UIHostingController(
      rootView: ComposeView(messageText: .constant(""))
    )

    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    loadMessages()
    setupNavigationBar()
  }

  private func setupUI() {
    view.backgroundColor = .systemBackground

    // Add child view controllers
    addChild(messagesHostingController)
    addChild(composeHostingController)

    // Add and configure views
    view.addSubview(messagesHostingController.view)
    view.addSubview(composeHostingController.view)

    messagesHostingController.view.translatesAutoresizingMaskIntoConstraints = false
    composeHostingController.view.translatesAutoresizingMaskIntoConstraints = false

    // Setup constraints
    NSLayoutConstraint.activate([
      messagesHostingController.view.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor),
      messagesHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      messagesHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      messagesHostingController.view.bottomAnchor.constraint(
        equalTo: composeHostingController.view.topAnchor),

      composeHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composeHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      composeHostingController.view.bottomAnchor.constraint(
        equalTo: view.keyboardLayoutGuide.topAnchor),
    ])

    messagesHostingController.didMove(toParent: self)
    composeHostingController.didMove(toParent: self)
  }

  private func setupNavigationBar() {
    if case .user = peer, let user = fullChatViewModel.peerUser {
      let headerView = ChatHeaderView()
      headerView.configure(with: user, parentVC: self) { [weak self] in
        self?.navigationController?.popViewController(animated: true)
      }
      navigationItem.titleView = headerView
    }
    navigationController?.setNavigationBarHidden(false, animated: false)
  }

  private func loadMessages() {
    Task {
      try await DataManager.shared.getChatHistory(
        peerUserId: nil,
        peerThreadId: nil,
        peerId: peer
      )

      await MainActor.run {
        messagesHostingController.rootView = MessagesCollectionView(
          fullMessages: fullChatViewModel.fullMessages
        )
      }
    }
  }

  private func sendMessage(text: String) {
    Task {
      do {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let chatId = fullChatViewModel.chat?.id else { return }

        let peerUserId: Int64? = if case .user(let id) = peer { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peer { id } else { nil }

        let randomId = Int64.random(in: Int64.min...Int64.max)
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: text,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId,
          out: true
        )

        try await AppDatabase.shared.dbWriter.write { db in
          try message.save(db)
        }

        try await DataManager.shared.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: text,
          peerId: peer,
          randomId: randomId
        )

        // Add haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

      } catch {
        Log.shared.error("Failed to send message", error: error)
      }
    }
  }
}

struct ChatView: UIViewControllerRepresentable {
  let peer: Peer

  func makeUIViewController(context: Context) -> ChatViewController {
    ChatViewController(peer: peer)
  }

  func updateUIViewController(_ uiViewController: ChatViewController, context: Context) {
    // Update the view controller if needed
  }
}
