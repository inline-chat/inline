import InlineKit
import MarkdownKit
import SwiftUI

struct MessageView: View {
    let message: Message
    @Environment(\.appDatabase) var database: AppDatabase
    private let markdownRenderer = MarkdownKit.renderer()
        .with(theme: .default)
        .build()

    init(message: Message) {
        self.message = message
    }

    var body: some View {
        MessageContentView(text: message.text ?? "", renderer: markdownRenderer)
            .padding(10)
            .font(.body)
            .foregroundColor(.primary)
            .frame(minWidth: 40, alignment: .leading)
            .background(Color(.systemGray6).opacity(0.7))
            .cornerRadius(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(message.id)
            .contextMenu {
                Button("Copy") {
                    UIPasteboard.general.string = message.text ?? ""
                }
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            _ = try await database.dbWriter.write { db in
                                try Message.deleteOne(db, id: message.id)
                            }
                        } catch {
                            Log.shared.error("Failed to delete message", error: error)
                        }
                    }
                }
            }
    }
}

// Helper view to handle markdown rendering
private struct MessageContentView: UIViewRepresentable {
    let text: String
    let renderer: MarkdownRenderer

    func makeUIView(context _: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        return textView
    }

    func updateUIView(_ textView: UITextView, context _: Context) {
        Task { @MainActor in
            textView.attributedText = await renderer.render(text)
        }
    }
}

#Preview {
    MessageView(message: Message(date: Date.now, text: "Hello, world!", chatId: 1, fromId: 1))
}
