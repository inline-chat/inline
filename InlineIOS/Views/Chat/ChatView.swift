import Combine
import InlineKit
import InlineUI
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
    @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var dataManager: DataManager

    var chatId: Int64
    @State private var text: String = ""

    init(chatId: Int64) {
        self.chatId = chatId
        _fullChatViewModel = EnvironmentStateObject { env in
            FullChatViewModel(db: env.appDatabase, chatId: chatId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            chatMessages
            inputArea
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 2) {
                    InitialsCircle(name: fullChatViewModel.chat?.title ?? "Chat", size: 26)
                        .padding(.trailing, 6)
                    Text(fullChatViewModel.chat?.title ?? "Chat")
                        .font(.title3)
                        .fontWeight(.medium)
                }
            }
        }
        .toolbarRole(.editor)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private var chatMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(fullChatViewModel.messages.reversed()) { message in
                        MessageView(message: message)
                    }
                }
                .padding()
            }
            .onChange(of: fullChatViewModel.messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
            .introspect(.scrollView, on: .iOS(.v13, .v14, .v15, .v16, .v17, .v18)) { scrollView in
                scrollView.keyboardDismissMode = .interactive
            }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .ignoresSafeArea()
            HStack {
                TextField("Type a message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        sendMessage()
                    }
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .foregroundColor(text.isEmpty ? .secondary : .blue)
                        .font(.body)
                }
                .disabled(text.isEmpty)
            }
            .padding()
        }
        .background(.clear)
    }

    private func sendMessage() {
        Task {
            do {
                if !text.isEmpty {
                    try await dataManager.sendMessage(chatId: chatId, text: text)
                    text = ""
                }
            } catch {
                print("Failed to send message: \(error)")
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(fullChatViewModel.messages.first?.id, anchor: .center)
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(chatId: 12344)
            .appDatabase(.emptyWithChat())
    }
}
