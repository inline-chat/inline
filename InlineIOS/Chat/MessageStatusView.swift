import InlineKit
import SwiftUI

struct MessageStatusView: View {
  let status: MessageSendingStatus?

  var body: some View {
    Group {
      switch status {
      case .sending:
        ProgressView()
          .scaleEffect(0.7)
          .tint(.white)
      case .sent:
        Image(systemName: "checkmark")
          .foregroundColor(.white)
          .font(.system(size: 10))
      case .failed:
        Image(systemName: "exclamationmark")
          .foregroundColor(.white)
          .font(.system(size: 10))
      case .none:
        EmptyView()
      }
    }
    
    .frame(width: 10, height: 10)
  }
}
