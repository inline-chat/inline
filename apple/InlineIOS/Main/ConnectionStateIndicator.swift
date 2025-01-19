import InlineKit
import SwiftUI

struct ConnectionStateIndicator: View {
  let state: ConnectionState

  @State private var circleScale: CGFloat = 1.0
  @State private var opacity: CGFloat = 1.0
  @State private var hideState: Bool = false

  var body: some View {
    HStack(spacing: 8) {
      if state != .normal {
        switch state {
        case .connecting:
          Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .scaleEffect(circleScale)

          Text("Connecting")
            .font(.callout)
            .foregroundColor(.primary)
            .opacity(opacity)

        case .updating:
          Circle()
            .fill(.orange)
            .frame(width: 12, height: 12)
            .scaleEffect(circleScale)

          Text("Connecting")
            .font(.callout)
            .foregroundColor(.primary)
            .opacity(opacity)

        case .normal:
          HStack {
            Circle()
              .fill(.green)
              .frame(width: 12, height: 12)

            Text("Connected")
              .font(.callout)
              .foregroundColor(.primary)
          }
          .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
              withAnimation {
                hideState = true
              }
            }
          }
          .opacity(hideState ? 0 : 1)
        }
      }
    }
    .onAppear {
      animateCircle()
      stateTextOpacity()
    }
  }

  private func animateCircle() {
    withAnimation(
      .easeInOut(duration: 0.8)
        .repeatForever(autoreverses: true)
    ) {
      circleScale = 0.8
    }
  }

  private func stateTextOpacity() {
    withAnimation(
      .easeInOut(duration: 0.8)
        .repeatForever(autoreverses: true)
    ) {
      opacity = 0.4
    }
  }
}
