import InlineKit
import InlineUI
import SwiftUI

struct ChatRowView: View {
    let item: ChatItem

    var body: some View {
        HStack {
            InitialsCircle(firstName: item.chat.type == .privateChat ? item.user?.firstName ?? "" : item.chat.title ?? "", lastName: item.chat.type == .privateChat ? item.user?.lastName ?? "" : nil, size: 26)
                .padding(.trailing, 6)
            Text(item.chat.type == .privateChat ? item.user?.firstName ?? "" : item.chat.title ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
