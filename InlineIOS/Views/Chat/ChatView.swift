import Combine
import InlineKit
import InlineUI
import MarkdownKit
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
    @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var dataManager: DataManager

    var chatId: Int64
    @State private var text: String = ""
    @State private var isEditing = false

    // Create markdown editor
    private let markdownEditor = MarkdownKit.editor()
        .with(theme: .default)
        .with(features: [.bold, .italic, .codeBlock, .bulletList, .numberList, .link])
        .build()

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

            // Add markdown formatting toolbar when editing
            if isEditing {
                ToolbarItemGroup(placement: .keyboard) {
                    markdownFormatButtons
                }
            }
        }
        .toolbarRole(.editor)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private var markdownFormatButtons: some View {
        HStack {
            Button(action: { formatText(.bold) }) {
                Image(systemName: "bold")
            }
            Button(action: { formatText(.italic) }) {
                Image(systemName: "italic")
            }
            Button(action: { formatText(.codeBlock) }) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            Button(action: { formatText(.bulletList) }) {
                Image(systemName: "list.bullet")
            }
            Button(action: { formatText(.numberList) }) {
                Image(systemName: "list.number")
            }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .ignoresSafeArea()
            HStack {
                MarkdownInputView(text: $text, isEditing: $isEditing)
                    .frame(minHeight: 36, maxHeight: 120)
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

    private func formatText(_ feature: MarkdownFeature) {
        switch feature {
        case .bold:
            markdownEditor.makeBold()
        case .italic:
            markdownEditor.makeItalic()
        case .codeBlock:
            markdownEditor.makeCodeBlock()
        case .bulletList:
            markdownEditor.addListItem()
        case .numberList:
            markdownEditor.addListItem(numbered: true)
        default:
            break
        }
    }

    private var chatMessages: some View {
        MessagesCollectionView(messages: fullChatViewModel.messages)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// Helper view to handle markdown input
private struct MarkdownInputView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool

    func makeUIView(context: Context) -> MarkdownTextView {
        let textView = MarkdownKit.editor()
            .with(theme: .default)
            .with(features: [.bold, .italic, .codeBlock, .bulletList, .numberList, .link, .autoFormatting])
            .build()

        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        
        return textView
    }

    func updateUIView(_ textView: MarkdownTextView, context _: Context) {
        if textView.text != text {
            textView.text = text
        }
        
        let size = textView.sizeThatFits(CGSize(width: textView.frame.width, height: .infinity))
        if textView.frame.size.height != size.height {
            textView.frame.size.height = size.height
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownInputView

        init(parent: MarkdownInputView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_: UITextView) {
            parent.isEditing = true
        }

        func textViewDidEndEditing(_: UITextView) {
            parent.isEditing = false
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(chatId: 12344)
            .appDatabase(.emptyWithChat())
    }
}
