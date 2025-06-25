import InlineKit
import SwiftUI

struct AlphaSheet: View {
  @AppStorage("alphaText") private var text: String = ""

  var body: some View {
    ScrollView {
      LazyVStack {
        Text(.init(text))
      }
      .padding(.horizontal, 18)
      .animation(.easeInOut(duration: 0.3), value: text)
    }

    .onAppear {
      Task {
        if let newText = try? await ApiClient.shared.getAlphaText() {
          text = newText
        }
      }
    }
  }
}
