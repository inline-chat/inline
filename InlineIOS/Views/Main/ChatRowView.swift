import InlineKit
import InlineUI
import SwiftUI

struct ChatRowView: View {
    let item: ChatItem

    var body: some View {
        HStack {
            InitialsCircle(name: item.chat.type == .privateChat ? item.user?.firstName ?? "" : item.chat.title ?? "", size: 26)
                .padding(.trailing, 6)
            Text(item.chat.type == .privateChat ? item.user?.firstName ?? "" : item.chat.title ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
