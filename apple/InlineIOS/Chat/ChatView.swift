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
  private let text: Binding<String>
  var onSendMessage: (() -> Void)?

  // MARK: - Initialization

  init(frame: CGRect, fullMessages: [FullMessage], text: Binding<String>) {
    self.text = text
    self.messagesView = MessagesCollectionView(fullMessages: fullMessages)

    super.init(frame: frame)

    setupViews()

    composeView.onTextChange = { [weak self] newText in

      self?.text.wrappedValue = newText
    }
    composeView.onSend = { [weak self] in
      print("Send called")
      self?.onSendMessage?()
    }

    composeView.text = text.wrappedValue

    contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var didSetupConstraints = false

  override func didMoveToWindow() {
    super.didMoveToWindow()

    // Only setup once when we have a valid window/hierarchy
    guard !didSetupConstraints else { return }
    didSetupConstraints = true

    setupViews()
  }

  private func setupViews() {
    // Add contentView to main view
    addSubview(contentView)
    contentView.translatesAutoresizingMaskIntoConstraints = false

    // Add views to contentView
    contentView.addSubview(messagesView)
    contentView.addSubview(composeView)

    messagesView.translatesAutoresizingMaskIntoConstraints = false
    composeView.translatesAutoresizingMaskIntoConstraints = false

    // Setup constraints
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
      messagesView.bottomAnchor.constraint(equalTo: composeView.topAnchor),

      // ComposeView constraints
      composeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      composeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      composeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    print("ContentView frame: \(contentView.frame)")
    print("Compose frame: \(composeView.frame)")
  }

  func updateMessages(_ messages: [FullMessage]) {
    messagesView.updateMessages(messages)
  }
}

// MARK: - ChatContainerViewRepresentable (SwiftUI Bridge)

struct ChatContainerViewRepresentable: UIViewRepresentable {
  var fullMessages: [FullMessage]
  var text: Binding<String>
  var onSendMessage: () -> Void

  func makeUIView(context: Context) -> ChatContainerView {
    let view = ChatContainerView(
      frame: .zero,
      fullMessages: fullMessages,
      text: text
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
      onSendMessage: sendMessage
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
          status: .sending
        )

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
          randomId: randomId
        )
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
