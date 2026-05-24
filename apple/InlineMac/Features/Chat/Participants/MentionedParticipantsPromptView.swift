import InlineKit
import InlineUI
import SwiftUI

struct MentionedParticipantsPromptView: View {
  let users: [UserInfo]
  let isAdding: Bool
  let onAdd: () -> Void

  private var title: String {
    if users.count == 1, let user = users.first {
      return "Add \(user.user.displayName)?"
    }

    return "Add \(users.count) people?"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: users.count == 1 ? 0 : 10) {
      HStack(spacing: 10) {
        if users.count == 1, let firstUser = users.first {
          UserAvatar(user: firstUser.user, size: 30)
        }

        Text(title)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 12)

        Button("Add", action: onAdd)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(isAdding)
      }

      if users.count > 1 {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(users) { user in
              MentionedParticipantPromptRow(user: user)
            }
          }
        }
        .frame(maxHeight: 190)
      }
    }
    .padding(12)
    .frame(width: users.count == 1 ? 260 : 280)
  }
}

private struct MentionedParticipantPromptRow: View {
  let user: UserInfo

  var body: some View {
    HStack(spacing: 8) {
      UserAvatar(user: user.user, size: 28)

      Text(user.user.displayName)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)
    }
  }
}
