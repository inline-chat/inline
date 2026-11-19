import SwiftUI

/// Date header for chat info resource tabs, matching the chat's date separator when pinned.
struct ChatInfoDateBadge: View {
  let dateText: String
  var isPinned = false

  var body: some View {
    if #available(iOS 26.0, *) {
      label
        .foregroundStyle(isPinned ? .primary : .secondary)
        .glassEffect(isPinned ? .regular.interactive() : .identity, in: .capsule)
        .animation(.smooth(duration: 0.25), value: isPinned)
    } else {
      label
        .foregroundStyle(.secondary)
        .background(
          Capsule()
            .fill(Color(.systemBackground).opacity(0.95))
        )
    }
  }

  private var label: some View {
    Text(dateText)
      .font(.subheadline)
      .fontWeight(.medium)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(Capsule())
      .accessibilityAddTraits(.isHeader)
  }
}
