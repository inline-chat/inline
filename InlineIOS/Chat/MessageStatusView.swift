import InlineKit
import SwiftUI

struct MessageMetadataView: View {
  let date: Date
  let status: MessageSendingStatus?
  let isOutgoing: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text(date.formatted(.dateTime.hour().minute()))
        .font(.system(size: 11))
        .foregroundColor(isOutgoing ? .white.opacity(0.7) : .gray)

      if isOutgoing && status != nil {
        Group {
          switch status {
          case .sent:
            Image(systemName: "checkmark")
              .font(.system(size: 11))
          case .sending:
            Image(systemName: "checkmark.circle")
              .font(.system(size: 11))
          case .failed:
            Image(systemName: "exclamationmark")
              .font(.system(size: 11))
          case .none:
            EmptyView()
          }
        }
        .foregroundColor(statusColor)
      }
    }
  }

  private var statusColor: Color {
    if status == .failed {
      return isOutgoing ? .white.opacity(0.7) : .red
    }
    return isOutgoing ? .white.opacity(0.7) : .gray
  }
}
