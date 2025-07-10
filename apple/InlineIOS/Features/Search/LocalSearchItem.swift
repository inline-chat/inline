import InlineKit
import InlineUI
import SwiftUI

struct LocalSearchItem: View {
  var item: HomeSearchResultItem
  var action: (() -> Void)?

  var body: some View {
    Button(action: {
      action?()
    }) {
      HStack(alignment: .center, spacing: 9) {
        switch item {
          case let .thread(threadInfo):
            Circle()
              .fill(Color.blue)
              .frame(width: 34, height: 34)
              .overlay(
                Text(threadInfo.chat.emoji ?? "💬")
                  .font(.system(size: 16))
              )

            VStack(alignment: .leading, spacing: 0) {
              Text(threadInfo.chat.title ?? "")
                .font(.body)
                .themedPrimaryText()
                .lineLimit(1)

              if let spaceName = threadInfo.space?.name {
                Text(spaceName)
                  .font(.caption)
                  .themedSecondaryText()
                  .lineLimit(1)
              }
            }

          case let .user(user):
            UserAvatar(user: user, size: 34)

            Text(user.displayName)
              .font(.body)
              .themedPrimaryText()
              .lineLimit(1)
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
  }
}
