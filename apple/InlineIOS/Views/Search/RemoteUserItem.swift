import InlineKit
import InlineUI
import SwiftUI

struct RemoteUserItem: View {
  var user: ApiUser
  var action: (() -> Void)?

  var body: some View {
    Button(action: {
      action?()
    }) {
      HStack(alignment: .center, spacing: 9) {
        UserAvatar(apiUser: user, size: 34)

        VStack(alignment: .leading, spacing: 0) {
          Text(user.firstName ?? user.username ?? "")
            .font(.body)
            .foregroundColor(.primary)
            .lineLimit(1)

          if let username = user.username {
            Text("@\(username)")
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()
      }
    }
    .buttonStyle(.plain)
  }
}
