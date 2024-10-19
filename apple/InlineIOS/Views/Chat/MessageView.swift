import InlineKit
import SwiftUI

struct MessageView: View {
    let message: Message

    init(message: Message) {
        self.message = message
    }

    var body: some View {
        Text(message.text ?? "")
            .padding(10)
            .font(.body)
            .foregroundColor(.primary)
            .frame(minWidth: 40, alignment: .leading)
            .background(Color(.systemGray6).opacity(0.7))
            .cornerRadius(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(message.id)
    }
}

#Preview {
    MessageView(message: Message(date: Date.now, text: "Hello, world!", chatId: 1, fromId: 1))
}
