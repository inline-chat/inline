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
            
      if isOutgoing && status != nil {
        switch status {
        case .sent:
          Image(systemName: "checkmark")
            .font(.system(size: 11))
        case .sending:
          Image(systemName: "checkmark.circle")
            .font(.system(size: 11))
        case .failed:
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(.red)
        case .none:
          EmptyView()
        }
      }
    }
    .foregroundColor(statusColor)
  }
    
  private var statusColor: Color {
    if status == .failed {
      return .red
    }
    return isOutgoing ? .white.opacity(0.7) : .gray
  }
}
