import SwiftUI

struct InfoRow: View {
  let symbol: String
  let color: Color
  let title: String
  let value: String

  var body: some View {
    HStack {
      HStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(color)
          .frame(width: 28, height: 28)
          .overlay {
            Image(systemName: symbol)
              .foregroundColor(.white)
              .font(.caption)
          }

        Text(title)
          .font(.body)
          .fontWeight(.medium)
          .themedPrimaryText()
      }
      Spacer()
      Text(value)
        .themedSecondaryText()
    }
  }
}

#Preview {
  InfoRow(
    symbol: "lock",
    color: .pink,
    title: "Chat Type",
    value: "Private"
  )
  .padding()
}
