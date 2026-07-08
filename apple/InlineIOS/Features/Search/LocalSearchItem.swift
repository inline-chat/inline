import InlineKit
import InlineUI
import SwiftUI

struct LocalSearchItem: View {
  var item: HomeSearchResultItem
  var action: (() -> Void)?

  var body: some View {
    Button(action: {
      action?()
    }, label: {
      HStack(alignment: .center, spacing: 9) {
        switch item {
        case let .thread(threadInfo):
          ThreadIconView(
            ThreadIconDescriptor(chat: threadInfo.chat),
            size: .regular(34),
            shape: .circle
          )

          VStack(alignment: .leading, spacing: 0) {
            Text(threadInfo.chat.humanReadableTitle ?? "")
              .font(.body)
              .lineLimit(1)

            if let spaceName = threadInfo.space?.name {
              Text(spaceName)
                .font(.caption)
                .lineLimit(1)
            }
          }

        case let .user(user):
          UserAvatar(user: user, size: 34)

          Text(user.displayName)
            .font(.body)
            .lineLimit(1)
        }

        Spacer()
      }
    })
    .buttonStyle(.plain)
  }
}
