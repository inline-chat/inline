import SwiftUI

struct EmptyStateView: View {
  @Binding var showDmSheet: Bool
  @Binding var showSheet: Bool

  var body: some View {
    VStack {
      Text("🏡")
        .font(.largeTitle)
        .padding(.bottom, 6)

      Text("Home is empty")
        .font(.title2)
        .fontWeight(.bold)
      Text("Create a space or start a DM")
        .font(.subheadline)
        .foregroundColor(.secondary)

      HStack {
        Button("Create Space") {
          showSheet = true
        }
        .buttonStyle(.bordered)
        .tint(.secondary)

        Button("New DM") {
          showDmSheet = true
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
      }
    }
    .padding()
  }
}

#Preview("EmptyStateView") {
  EmptyStateView(showDmSheet: .constant(false), showSheet: .constant(false))
    .padding()
}
