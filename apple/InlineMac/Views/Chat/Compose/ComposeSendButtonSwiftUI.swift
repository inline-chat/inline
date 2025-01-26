import SwiftUI

struct ComposeSendButtonSwiftUI: View {
  @ObservedObject var state: ComposeSendButtonState
  var action: () -> Void
  @State private var isHovering = false

  private let size: CGFloat = Theme.composeButtonSize
  private let backgroundColor: Color = .accentColor
  private let hoveredBackgroundColor: Color = .accentColor.opacity(0.8)

  var body: some View {
    Group {
      if state.canSend {
        Button(action: action) {
          Image(systemName: "arrow.up")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .fontWeight(.semibold)
            .padding(5)
            .frame(width: size, height: size)
            .background(
              Circle()
                .fill(isHovering ? hoveredBackgroundColor : backgroundColor)
            )
            .scaleEffect(isHovering ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
          withAnimation(.easeInOut(duration: 0.2)) {
            isHovering = hovering
          }
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.15), value: state.canSend)
  }
}

//
// #Preview {
//  ComposeSendButtonSwiftUI(state: ComposeSendButtonState(canSend: true), action: {})
//    .frame(width: 100, height: 100)
// }
