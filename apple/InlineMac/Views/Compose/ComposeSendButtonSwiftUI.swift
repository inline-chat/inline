import SwiftUI

struct ComposeSendButtonSwiftUI: View {
  @ObservedObject var state: ComposeSendButtonState
  var action: () -> Void
  var sendWithoutNotification: () -> Void
  @State private var isHovering = false

  private let size: CGFloat = Theme.composeButtonSize
  private let backgroundColor: Color = .accent
  private let hoveredBackgroundColor: Color = .accent.opacity(0.8)
  private let disabledBackgroundColor: Color = Color(nsColor: .quinaryLabel)

  var body: some View {
    let isEnabled = state.canSend
    let targetSize = isEnabled ? size : size * 0.9
    let iconSize = isEnabled ? 16.0 : 14.0
    let padding = isEnabled ? 5.0 : 4.0
    Button(action: action) {
      Image(systemName: "arrow.up")
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(.white)
        .padding(padding)
        .frame(width: targetSize, height: targetSize)
        .background(
          Circle()
            .fill(isEnabled ? (isHovering ? hoveredBackgroundColor : backgroundColor) : disabledBackgroundColor)
        )
        .scaleEffect(isEnabled && isHovering ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
    .buttonStyle(.plain)
    .allowsHitTesting(isEnabled)
    .opacity(1.0)
    .contextMenu {
      if isEnabled {
        Button("Send without notification") {
          sendWithoutNotification()
        }
      }
    }
    .onHover { hovering in
      guard isEnabled else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        isHovering = hovering
      }
    }
    .animation(.easeInOut(duration: 0.15), value: isEnabled)
  }
}

//
// #Preview {
//  ComposeSendButtonSwiftUI(state: ComposeSendButtonState(canSend: true), action: {})
//    .frame(width: 100, height: 100)
// }
