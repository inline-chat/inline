import SwiftUI

struct TypingText: View {
  let fullText: String
  @State private var displayedText = ""
  let typingInterval: TimeInterval

  init(_ text: String, typingInterval: TimeInterval = 0.2) {
    fullText = text
    self.typingInterval = typingInterval
  }

  var body: some View {
    Text(displayedText)
      .onAppear { animateText() }
  }

  private func animateText() {
    for (index, character) in fullText.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + typingInterval * Double(index)) {
        displayedText += String(character)
      }
    }
  }
}
