import InlineKit
import InlineUI
import SwiftUI

struct MentionedParticipantsPromptView: View {
  let items: [MentionCompletionItem]
  let isAdding: Bool
  let onAdd: () -> Void

  private var title: String {
    if items.count == 1, let item = items.first {
      return "Add \(item.title)?"
    }

    return "Add \(items.count) mentions?"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: items.count == 1 ? 0 : 10) {
      HStack(spacing: 10) {
        if items.count == 1, let item = items.first {
          MentionedParticipantPromptIcon(item: item, size: 30)
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

      if items.count > 1 {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
              MentionedParticipantPromptRow(item: item)
            }
          }
        }
        .frame(maxHeight: 190)
      }
    }
    .padding(12)
    .frame(width: items.count == 1 ? 260 : 280)
  }
}

private struct MentionedParticipantPromptRow: View {
  let item: MentionCompletionItem

  var body: some View {
    HStack(spacing: 8) {
      MentionedParticipantPromptIcon(item: item, size: 28)

      Text(item.title)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)
    }
  }
}

private struct MentionedParticipantPromptIcon: View {
  let item: MentionCompletionItem
  let size: CGFloat

  var body: some View {
    switch item {
      case let .user(user):
        UserAvatar(user: user.userInfo.user, size: size)

      case .group:
        Image(systemName: "person.2.fill")
          .font(.system(size: max(12, size * 0.42), weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
          .background(.quaternary)
          .clipShape(Circle())
    }
  }
}
