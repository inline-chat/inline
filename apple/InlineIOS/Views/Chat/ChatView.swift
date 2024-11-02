import Combine
import InlineKit
import InlineUI
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
    // MARK: - Properties

    @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var dataManager: DataManager

    let chatId: Int64
    @State private var text: String = ""

    // MARK: - Initialization

    init(chatId: Int64) {
        self.chatId = chatId
        _fullChatViewModel = EnvironmentStateObject { env in
            FullChatViewModel(db: env.appDatabase, chatId: chatId)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            chatMessages
            inputArea
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                chatHeader
            }
        }
        .toolbarRole(.editor)
        .onTapGesture(perform: dismissKeyboard)
    }
}

// MARK: - View Components

private extension ChatView {
    var chatMessages: some View {
        MessagesCollectionView(messages: fullChatViewModel.messages)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var chatHeader: some View {
        HStack(spacing: 2) {
            InitialsCircle(firstName: fullChatViewModel.chat?.title ?? "Chat", lastName: nil, size: 26)
                .padding(.trailing, 6)
            Text(fullChatViewModel.chat?.title ?? "Chat")
                .font(.title3)
                .fontWeight(.medium)
        }
    }

    var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .ignoresSafeArea()
            HStack {
                messageTextField
                sendButton
            }
            .padding()
        }
        .background(.clear)
    }

    var messageTextField: some View {
        TextField("Type a message", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .onSubmit(sendMessage)
    }

    var sendButton: some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .foregroundColor(text.isEmpty ? .secondary : .blue)
                .font(.body)
        }
        .disabled(text.isEmpty)
    }
}

// MARK: - Actions

private extension ChatView {
    func dismissKeyboard() {
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
                if !text.isEmpty {
                    try await dataManager.sendMessage(chatId: chatId, text: text)
                    text = ""
                }
            } catch {
                Log.shared.error("Failed to send message", error: error)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChatView(chatId: 12344)
            .appDatabase(.emptyWithChat())
    }
}
