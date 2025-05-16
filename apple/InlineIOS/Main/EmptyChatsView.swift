import SwiftUI

struct EmptyChatsView: View {
  let isArchived: Bool

  var body: some View {
    VStack {
      Spacer()
      Image(systemName: isArchived ? "tray.fill" : "bubble.left.and.bubble.right.fill")
        .foregroundColor(.secondary)
        .font(.title)
        .padding(.bottom, 6)
      Text(isArchived ? "No archived chats" : "No chats")
        .font(.title3)
      Spacer()
    }
  }
}
