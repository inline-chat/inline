
import SwiftUI

struct ErrorView: View {
  let errorMessage: String
  let retryAction: (() -> Void)?

  var body: some View {
    VStack(spacing: 4) {
      let symbol =
        Image(systemName: "exclamationmark.icloud.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 34, height: 34)
          .foregroundColor(.indigo)
          .symbolRenderingMode(.monochrome)

      if #available(macOS 15.0, *) {
        symbol.symbolEffect(
          .wiggle, options: .repeat(.periodic).speed(1.2), isActive: true
        )
      } else {
        symbol
      }

      Text("Chat failed to load.")
        .font(.headline)
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
  ErrorView(errorMessage: "Failed to load chat. Please try again later.", retryAction: nil)
    .frame(width: 400, height: 400)
}
