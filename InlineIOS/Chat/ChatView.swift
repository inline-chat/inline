import Combine
import InlineKit
import InlineUI
import SwiftUI
import UIKit

// MARK: - ChatContainerView (UIKit)

class ChatContainerView: UIView {
  // MARK: - Properties

  private let contentView = UIView()
  private let messagesView: MessagesCollectionView
  private let composeView = ComposeView()
  private let topComposeView: UIHostingController<TopComposeView>
  private let composeStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 0
    stack.alignment = .fill
    return stack
  }()

  private let text: Binding<String>
  var onSendMessage: (() -> Void)?
  var chatId: Int64

  // MARK: - Initialization

  init(frame: CGRect, fullMessages: [FullMessage], text: Binding<String>, chatId: Int64) {
    self.text = text
    self.chatId = chatId
    self.messagesView = MessagesCollectionView(fullMessages: fullMessages)

    let state = ChatState.shared.getState(chatId: chatId)
    self.topComposeView = UIHostingController(
      rootView: TopComposeView(
        replyingMessageId: state.replyingMessageId ?? 0,
        chatId: chatId
      )
    )

    super.init(frame: frame)

    setupViews()
    setupChatStateObserver()
    setupComposeView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup Methods

  private func setupViews() {
    // Add contentView to main view
    addSubview(contentView)
    contentView.translatesAutoresizingMaskIntoConstraints = false

    // Add views to contentView
    contentView.addSubview(messagesView)
    contentView.addSubview(composeStack)

    // Setup compose stack
    composeStack.translatesAutoresizingMaskIntoConstraints = false
    composeStack.addArrangedSubview(topComposeView.view)
    composeStack.addArrangedSubview(composeView)

    messagesView.translatesAutoresizingMaskIntoConstraints = false
    topComposeView.view.translatesAutoresizingMaskIntoConstraints = false
    composeView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      // ContentView constraints
      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),

      // MessagesView constraints
      messagesView.topAnchor.constraint(equalTo: contentView.topAnchor),
      messagesView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      messagesView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      messagesView.bottomAnchor.constraint(equalTo: composeStack.topAnchor),

      // ComposeStack constraints
      composeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      composeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      composeStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      // Fixed height for topComposeView
      topComposeView.view.heightAnchor.constraint(equalToConstant: 58),
    ])

    // Initial state
    topComposeView.view.isHidden =
      ChatState.shared.getState(chatId: chatId).replyingMessageId == nil
  }

  private func setupComposeView() {
    composeView.onTextChange = { [weak self] newText in
      self?.text.wrappedValue = newText
    }
    composeView.onSend = { [weak self] in
      self?.onSendMessage?()
    }
    composeView.text = text.wrappedValue
  }

  private func setupChatStateObserver() {
    Task { @MainActor in
      for await _ in ChatState.shared.$states.values {
        updateTopComposeView()
      }
    }
  }

  // MARK: - Update Methods

  private func updateTopComposeView() {
    if let replyingId = ChatState.shared.getState(chatId: chatId).replyingMessageId {
      print("Showing reply view for message: \(replyingId)")
      topComposeView.rootView = TopComposeView(replyingMessageId: replyingId, chatId: chatId)

      if topComposeView.view.isHidden {
        topComposeView.view.alpha = 0
        topComposeView.view.isHidden = false

        UIView.animate(withDuration: 0.3) {
          self.topComposeView.view.alpha = 1
          self.layoutIfNeeded()
        }
      }
    } else {
      print("Hiding reply view")
      guard !topComposeView.view.isHidden else { return }

      UIView.animate(withDuration: 0.3) {
        self.topComposeView.view.alpha = 0
      } completion: { _ in
        self.topComposeView.view.isHidden = true
        self.layoutIfNeeded()
      }
    }
  }

  func updateMessages(_ messages: [FullMessage]) {
    messagesView.updateMessages(messages)
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    print("ContentView frame: \(contentView.frame)")
    print("TopComposeView frame: \(topComposeView.view.frame)")
    print("Compose frame: \(composeView.frame)")
  }
}

// MARK: - ChatContainerViewRepresentable (SwiftUI Bridge)

struct ChatContainerViewRepresentable: UIViewRepresentable {
  var fullMessages: [FullMessage]
  var text: Binding<String>
  var onSendMessage: () -> Void
  var chatId: Int64
  func makeUIView(context: Context) -> ChatContainerView {
    let view = ChatContainerView(
      frame: .zero,
      fullMessages: fullMessages,
      text: text,
      chatId: chatId
    )
    view.onSendMessage = onSendMessage
    return view
  }

  func updateUIView(_ uiView: ChatContainerView, context: Context) {
    // Only update messages if they've changed
    if context.coordinator.previousMessages != fullMessages {
      uiView.updateMessages(fullMessages)
      context.coordinator.previousMessages = fullMessages
    }

    uiView.onSendMessage = onSendMessage
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(fullMessages: fullMessages)
  }

  class Coordinator {
    var previousMessages: [FullMessage]

    init(fullMessages: [FullMessage]) {
      self.previousMessages = fullMessages
    }
  }
}

// MARK: - ChatView (SwiftUI)

struct ChatView: View {
  var peer: Peer
  @State var text: String = ""

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var dataManager: DataManager

  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase

  init(peer: Peer) {
    self.peer = peer
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer)
    }
  }

  var body: some View {
    ChatContainerViewRepresentable(
      fullMessages: fullChatViewModel.fullMessages,
      text: $text,
      onSendMessage: sendMessage,
      chatId: fullChatViewModel.chat?.id ?? 0
    )
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text(title)
          .font(.body)
          .fontWeight(.semibold)
      }
    }
    .navigationBarHidden(false)
    .toolbarRole(.editor)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .onAppear {
      fetchMessages()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        fetchMessages()
      }
    }
  }

  // MARK: - Helper Properties

  var title: String {
    if case .user = peer {
      return fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      return fullChatViewModel.chat?.title ?? ""
    }
  }

  // MARK: - Helper Methods

  private func fetchMessages() {
    Task {
      do {
        try await dataManager.getChatHistory(
          peerUserId: nil,
          peerThreadId: nil,
          peerId: peer
        )
      } catch {
        Log.shared.error("Failed to fetch messages", error: error)
      }
    }
  }

  func sendMessage() {
    Task {
      do {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let chatId = fullChatViewModel.chat?.id else { return }

        let messageText = text
        let state = ChatState.shared.getState(chatId: chatId)

        // Add haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()

        withAnimation {
          text = ""
        }

        let peerUserId: Int64? = if case .user(let id) = peer { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peer { id } else { nil }

        let randomId = Int64.random(in: Int64.min ... Int64.max)
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: messageText,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId,
          out: true,
          status: .sending,
          repliedToMessageId: state.replyingMessageId
        )

        print("Sending message with repliedToMessageId: \(message.repliedToMessageId) \(message)")
        // Save message to database
        try await database.dbWriter.write { db in
          try message.save(db)
        }

        // Send message to server
        try await dataManager.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: messageText,
          peerId: peer,
          randomId: randomId,
          repliedToMessageId: message.repliedToMessageId
        )
        ChatState.shared.clearReplyingMessageId(chatId: chatId)
      } catch {
        Log.shared.error("Failed to send message", error: error)
      }
    }
  }
}

// MARK: - Helper Extensions

extension UIView {
  var parentViewController: UIViewController? {
    var parentResponder: UIResponder? = self
    while parentResponder != nil {
      parentResponder = parentResponder?.next
      if let viewController = parentResponder as? UIViewController {
        return viewController
      }
    }
    return nil
  }
}
