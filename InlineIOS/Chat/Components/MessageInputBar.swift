import InlineKit
import InlineUI
import SwiftUI

struct MessageInputBar: View {
  @Binding var text: String
  @Binding var textViewHeight: CGFloat
  var peerId: Peer
  var onSend: () -> Void

  var body: some View {
    HStack(alignment: .bottom) {
      ZStack(alignment: .leading) {
        TextView(
          text: $text,
          height: $textViewHeight
        )
        .frame(height: textViewHeight)
        .background(.clear)
        .onChange(of: text) { newText in
          if newText.isEmpty {
            Task { await ComposeActions.shared.stoppedTyping(for: peerId) }
          } else {
            Task { await ComposeActions.shared.startedTyping(for: peerId) }
          }
        }

        if text.isEmpty {
          Text("Write a message")
            .foregroundStyle(.tertiary)
            .padding(.leading, 6)
            .padding(.vertical, 6)
            .allowsHitTesting(false)
            .transition(
              .asymmetric(
                insertion: .offset(x: 40).combined(with: .opacity),
                removal: .offset(x: 40).combined(with: .opacity)
              )
            )
        }
      }
      .animation(.smoothSnappy, value: textViewHeight)
      .animation(.smoothSnappy, value: text.isEmpty)

      Button { onSend()
        text = ""
      } label: {
        Circle()
          .fill(text.isEmpty ? Color(.systemGray5) : .blue)
          .frame(width: 28, height: 28)
          .overlay {
            Image(systemName: "arrow.up")
              .font(.callout)
              .foregroundStyle(text.isEmpty ? Color(.tertiaryLabel) : .white)
          }
      }
      .padding(.bottom, 6)
    }
    .padding(.vertical, 6)
    .padding(.horizontal)
    .background(Color(uiColor: .systemBackground))
  }
}
