import InlineKit
import InlineUI
import SwiftUI

struct ChatItemRow: View {
  let item: SpaceChatItem
  @Environment(Router.self) private var router
  @EnvironmentObject private var data: DataManager

  var hasUnread: Bool {
    item.dialog.unreadCount ?? 0 > 0
  }

  private var chatProfileColors: [Color] {
    let _ = colorScheme
    return [
      Color(.systemGray3).adjustLuminosity(by: 0.2),
      Color(.systemGray5).adjustLuminosity(by: 0),
    ]
  }

  var body: some View {
    Button {
      router.push(.chat(peer: item.peerId))
    } label: {
      HStack(alignment: .center, spacing: 0) {
        HStack(alignment: .center, spacing: 5) {
          Circle()
            .fill(hasUnread ? ColorManager.shared.swiftUIColor : .clear)
            .frame(width: 6, height: 6)
            .animation(.easeInOut(duration: 0.3), value: hasUnread)
          Circle()
            .fill(
              LinearGradient(
                colors: chatProfileColors,
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .frame(width: 32, height: 32)
            .overlay {
              Group {
                if let emoji = item.chat?.emoji {
                  Text(
                    String(describing: emoji).replacingOccurrences(of: "Optional(\"", with: "")
                      .replacingOccurrences(of: "\")", with: "")
                  )
                  .font(.callout)
                } else {
                  Text("💬")
                    .font(.callout)
                }
              }
            }
        }
        Text(item.chat?.title ?? "Chat")
          .font(.body)
          .padding(.leading, 8)
      }
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        Task {
          try await data.updateDialog(
            peerId: item.peerId,
            archived: true
          )
        }
      } label: {
        Image(systemName: "tray.and.arrow.down.fill")
      }
      .tint(Color(.systemGray2))

      Button {
        Task {
          try await data.updateDialog(
            peerId: item.peerId,
            pinned: !(item.dialog.pinned ?? false)
          )
        }
      } label: {
        Image(systemName: item.dialog.pinned ?? false ? "pin.slash.fill" : "pin.fill")
      }
      .tint(.indigo)
    }
  }
}
