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
    }

    .onAppear {
      Task {
        if text.isEmpty {
          if let newText = try? await ApiClient.shared.getAlphaText() {
            text = newText
          }
        }
      }
    }
  }
}
