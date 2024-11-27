import InlineKit
import SwiftUI
import UIKit

struct ComposeView: View {
  @Binding var messageText: String
  @State private var textViewHeight: CGFloat = 40

  var body: some View {
    ZStack(alignment: .leading) {
      Compose(
        text: $messageText,
        placeholder: "",
        maxHeight: 300,
        height: $textViewHeight
      )
      .frame(height: textViewHeight)
      .background(Color.clear)
      .animation(.smoothSnappy, value: textViewHeight)

      ZStack {
        if messageText.isEmpty {
          Text("Write a message")
            .foregroundStyle(.tertiary)
            .padding(.leading, 6)
            .allowsHitTesting(false)
            .frame(height: textViewHeight)
            .transition(
              .asymmetric(
                insertion: .offset(x: 40),
                removal: .offset(x: 40)
              )
              .combined(with: .opacity)
            )
        }
      }
      .animation(.smoothSnappy, value: messageText.isEmpty)
    }
    .animation(.smoothSnappy, value: messageText.isEmpty)
  }
}