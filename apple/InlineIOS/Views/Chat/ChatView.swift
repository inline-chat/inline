import Combine
import InlineKit
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
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 2) {
                    Button(action: { nav.popToRoot() }) {
                        Image(systemName: "chevron.left")
                            .foregroundColor(.secondary)
                            .font(.body)
                    }
                    Text(fullChatViewModel.chat?.title ?? "Chat")
                        .font(.title3)
                        .fontWeight(.medium)
                }
            }
        }
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
            .introspect(.scrollView) { scrollView in
                scrollView.keyboardDismissMode = .interactive
            }
        }
        .keyboardAwareModifier()
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

extension View {
    func keyboardAwareModifier() -> some View {
        return modifier(KeyboardAwareModifier())
    }
}

struct KeyboardAwareModifier: ViewModifier {
    @State private var keyboardHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardHeight)
            .onAppear {
                NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { notification in
                    let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
                    keyboardHeight = keyboardFrame.height
                }
                NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
                    keyboardHeight = 0
                }
            }
    }
}
