import SwiftUI

struct ChatLoadErrorView: View {
  let retryAction: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      VStack(spacing: 4) {
        Text("Chat unavailable")
          .font(.headline)

        Text("You may not have access to this chat, or it may no longer exist.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      Button("Try Again", action: retryAction)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(.windowBackgroundColor))
    )
  }
}

#Preview {
  ChatLoadErrorView(retryAction: {})
    .frame(width: 400, height: 400)
}
