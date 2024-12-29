import Combine
import InlineKit
import InlineUI
import SwiftUI

struct ChatView: View {
  var peer: Peer

  @State var text: String = ""
  @State private var textViewHeight: CGFloat = 36

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var dataManager: DataManager
  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase

  @ObservedObject var composeActions: ComposeActions = .shared

  private func currentComposeAction() -> ApiComposeAction? {
    composeActions.getComposeAction(for: peer)?.action
  }

  static let formatter = RelativeDateTimeFormatter()
  private func getLastOnlineText(date: Date?) -> String {
    guard let date = date else { return "" }
    Self.formatter.dateTimeStyle = .named
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
  }

  var subtitle: String {
    if let composeAction = currentComposeAction() {
      return composeAction.rawValue
    } else if let online = fullChatViewModel.peerUser?.online {
      return online
        ? "online"
        : (fullChatViewModel.peerUser?.lastOnline != nil
          ? getLastOnlineText(date: fullChatViewModel.peerUser?.lastOnline) : "offline")
    } else {
      return "last seen recently"
    }
  }

  init(peer: Peer) {
    self.peer = peer
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer, limit: 80)
    }
  }

  // MARK: - Body

  var body: some View {
    ScrollView(
      .vertical,
      content: {
        LazyVStack(spacing: 2) {
          ForEach(fullChatViewModel.fullMessages, id: \.self) { fullMessage in
            MessageView(fullMessage: fullMessage)
          }
        }
        .frame(maxWidth: .infinity)
      }
    )
    .defaultScrollAnchor(.bottom)
    .safeAreaInset(edge: .bottom) {
      HStack(alignment: .bottom) {
        ZStack(alignment: .leading) {
          TextView(
            text: $text,
            height: $textViewHeight
          )

          .frame(height: textViewHeight)
          .background(.clear)
          .onChange(of: text) { newText in
            if newText.isEmpty {
              Task { await ComposeActions.shared.stoppedTyping(for: peer) }
            } else {
              Task { await ComposeActions.shared.startedTyping(for: peer) }
            }
          }
          if text.isEmpty {
            Text("Write a message")
              .foregroundStyle(.tertiary)
              .padding(.leading, 6)
              .padding(.vertical, 6)
              .allowsHitTesting(false)
              .transition(
                .asymmetric(
                  insertion: .offset(x: 40).combined(with: .opacity),
                  removal: .offset(x: 40).combined(with: .opacity)
                )
              )
          }
        }
        .animation(.smoothSnappy, value: textViewHeight)
        .animation(.smoothSnappy, value: text.isEmpty)

        sendButton
          .padding(.bottom, 6)

        //  inputArea
      }
      .padding(.vertical, 6)
      .padding(.horizontal)
      .background(Color(uiColor: .systemBackground))
    }
    //    VStack(spacing: 0) {
    //      MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages.reversed())
//            .safeAreaInset(edge: .bottom) {
//              HStack(alignment: .bottom) {
//                ZStack(alignment: .leading) {
//                  TextView(
//                    text: $text,
//                    height: $textViewHeight
//                  )
//
//                  .frame(height: textViewHeight)
//                  .background(.clear)
//                  .onChange(of: text) { newText in
//                    if newText.isEmpty {
//                      Task { await ComposeActions.shared.stoppedTyping(for: peer) }
//                    } else {
//                      Task { await ComposeActions.shared.startedTyping(for: peer) }
//                    }
//                  }
//                  if text.isEmpty {
//                    Text("Write a message")
//                      .foregroundStyle(.tertiary)
//                      .padding(.leading, 6)
//                      .padding(.vertical, 6)
//                      .allowsHitTesting(false)
//                      .transition(
//                        .asymmetric(
//                          insertion: .offset(x: 40).combined(with: .opacity),
//                          removal: .offset(x: 40).combined(with: .opacity)
//                        )
//                      )
//                  }
//                }
//                .animation(.smoothSnappy, value: textViewHeight)
//                .animation(.smoothSnappy, value: text.isEmpty)
//
//                sendButton
//                  .padding(.bottom, 6)
//
//                //  inputArea
//              }
//              .padding(.vertical, 6)
//              .padding(.horizontal)
//              .background(Color(uiColor: .systemBackground))
//            }
//        }
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack {
          Text(title)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      #if DEBUG
        ToolbarItem(placement: .topBarTrailing) {
          Button("Debug") {
            sendDebugMessages()
          }
        }
      #endif
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
}

// MARK: - Helper Methods

extension ChatView {
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

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
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

        // Delay clearing the text field to allow animation to complete
        withAnimation {
          text = ""
          textViewHeight = 36
        }

        let peerUserId: Int64? = if case .user(let id) = peer { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peer { id } else { nil }

        let randomId = Int64.random(in: Int64.min...Int64.max)
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
          repliedToMessageId: ChatState.shared.getState(chatId: chatId).replyingMessageId
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
          randomId: randomId,
          repliedToMessageId: ChatState.shared.getState(chatId: chatId).replyingMessageId
        )
      } catch {
        Log.shared.error("Failed to send message", error: error)
        // Optionally show error to user
      }
    }
  }

  private func sendDebugMessages() {
    Task {
      guard let chatId = fullChatViewModel.chat?.id else { return }

      // Send 80 messages with different lengths
      for i in 1...200 {
        let messageLength = Int.random(in: 10...200)
        let messageText = String(repeating: "Test message \(i) ", count: messageLength / 10)

        let peerUserId: Int64? = if case .user(let id) = peer { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peer { id } else { nil }

        let randomId = Int64.random(in: Int64.min...Int64.max)
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
          repliedToMessageId: nil
        )

        do {
          // Save to database
          try await database.dbWriter.write { db in
            try message.save(db)
          }

          // Send to server
          try await dataManager.sendMessage(
            chatId: chatId,
            peerUserId: peerUserId,
            peerThreadId: peerThreadId,
            text: messageText,
            peerId: peer,
            randomId: randomId,
            repliedToMessageId: nil
          )

          // Add small delay between messages
          try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        } catch {
          Log.shared.error("Failed to send debug message", error: error)
        }
      }
    }
  }
}

// MARK: - Helper Properties

extension ChatView {
  var title: String {
    if case .user = peer {
      return fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      return fullChatViewModel.chat?.title ?? ""
    }
  }
}

// MARK: - Views

extension ChatView {
  @ViewBuilder
  private var chatMessages: some View {
    MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages)
  }

  @ViewBuilder
  var sendButton: some View {
    Button {
      sendMessage()
    } label: {
      Circle()
        .fill(text.isEmpty ? Color(.systemGray5) : .blue)
        .frame(width: 28, height: 28)
        .overlay {
          Image(systemName: "paperplane.fill")
            .font(.callout)
            .foregroundStyle(text.isEmpty ? Color(.tertiaryLabel) : .white)
        }
    }

    .buttonStyle(CustomButtonStyle())
  }
}

struct CustomButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.8 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }
}

// MARK: - Message View

struct MessageView: View {
  let fullMessage: FullMessage
  @State private var showingContextMenu = false
  @Environment(\.colorScheme) var colorScheme

  private let horizontalPadding: CGFloat = 12
  private let verticalPadding: CGFloat = 8
  private let maxWidthMultiplier: CGFloat = 0.9

  var body: some View {
    HStack {
      if fullMessage.message.out == true {
        Spacer()
      }

      VStack(alignment: fullMessage.message.out == true ? .trailing : .leading, spacing: 4) {
        messageBubble
          .contextMenu {
            Button("Copy") {
              UIPasteboard.general.string = fullMessage.message.text
            }

            Button("Reply") {
              ChatState.shared.setReplyingMessageId(
                chatId: fullMessage.message.chatId ?? 0,
                id: fullMessage.message.id ?? 0
              )
            }
          }
      }

      if fullMessage.message.out == false {
        Spacer()
      }
    }
    .scaledToFill()
    .padding(.horizontal, 8)
  }

  private var messageBubble: some View {
    VStack(alignment: .trailing, spacing: 0) {
      if messageNeedsVerticalLayout {
        Text(fullMessage.message.text ?? "")
          .font(.system(size: 17))
          .foregroundColor(fullMessage.message.out == true ? .white : .primary)
          .multilineTextAlignment(.leading)

        MessageMetadataView(
          date: fullMessage.message.date,
          status: fullMessage.message.status,
          isOutgoing: fullMessage.message.out == true
        )
      } else {
        HStack(spacing: 8) {
          Text(fullMessage.message.text ?? "")
            .font(.system(size: 17))
            .foregroundColor(fullMessage.message.out == true ? .white : .primary)

          MessageMetadataView(
            date: fullMessage.message.date,
            status: fullMessage.message.status,
            isOutgoing: fullMessage.message.out == true
          )
        }
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .background(
      fullMessage.message.out == true ? .blue : Color(UIColor.systemGray5.withAlphaComponent(0.4))
    )
    .cornerRadius(18)
  }

  private var messageNeedsVerticalLayout: Bool {
    let messageLength = fullMessage.message.text?.count ?? 0
    let messageText = fullMessage.message.text ?? ""
    return messageLength > 22 || messageText.contains("\n")
  }
}

// MARK: - Message Metadata View

struct MessageMetadataView: View {
  let date: Date
  let status: MessageSendingStatus?
  let isOutgoing: Bool

  private let symbolSize: CGFloat = 8

  var body: some View {
    HStack(spacing: 4) {
      Text(timeString)
        .font(.system(size: 11))
        .foregroundColor(textColor)

      if isOutgoing, let status = status {
        statusImage(for: status)
          .font(.system(size: symbolSize, weight: .medium))
          .foregroundColor(textColor)
      }
    }
  }

  private var timeString: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }

  private var textColor: Color {
    isOutgoing ? .white.opacity(0.7) : .gray
  }

  private func statusImage(for status: MessageSendingStatus) -> Image {
    switch status {
    case .sent:
      return Image(systemName: "checkmark")
    case .sending:
      return Image(systemName: "clock")
    case .failed:
      return Image(systemName: "exclamationmark")
    }
  }
}
