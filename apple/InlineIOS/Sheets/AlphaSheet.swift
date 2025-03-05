import InlineKit
import SwiftUI

struct AlphaSheet: View {
  @State private var text: String = ""
  var body: some View {
    VStack {
      Text(.init(text))
    }
    .padding(.horizontal, 18)
    .onAppear {
      Task {
        text = try await ApiClient.shared.getAlphaText()
      }
    }
  }
}
