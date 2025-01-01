import InlineKit
import SwiftUI

struct MessageBubble: View {
  let messageText: String
  let isOutgoing: Bool
  let isLongMessage: Bool

  var body: some View {
    HStack {
      if isOutgoing {
        Spacer()
      }

      VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
        if isLongMessage {
          Text(messageText)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .foregroundColor(isOutgoing ? .white : .primary)

          Text(Date().formatted(date: .omitted, time: .shortened))
            .font(.caption)
            .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        } else {
          HStack(spacing: 8) {
            Text(messageText)
              .foregroundColor(isOutgoing ? .white : .primary)

            Text(Date().formatted(date: .omitted, time: .shortened))
              .font(.caption)
              .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
      }
      .background(
        isOutgoing
          ? ColorManager.shared.swiftUIColor
          : Color(uiColor: .systemGray5.withAlphaComponent(0.4))
      )
      .cornerRadius(18)
      .frame(
        maxWidth: UIScreen.main.bounds.width * 0.96,
        alignment: isOutgoing ? .trailing : .leading
      )

      if !isOutgoing {
        Spacer()
      }
    }
    .padding(.horizontal, 8)
  }
}
