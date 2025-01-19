import SwiftUI

struct SwipeBackModifier: ViewModifier {
  @Environment(\.presentationMode) var presentationMode
  @GestureState private var dragOffset = CGSize.zero

  func body(content: Content) -> some View {
    GeometryReader { geometry in
      content
        .offset(x: dragOffset.width)
        .gesture(
          DragGesture()
            .updating($dragOffset) { value, state, _ in
              if value.translation.width > 0 {
                state = value.translation
              }
            }
            .onEnded { value in
              if value.translation.width > geometry.size.width * 0.3 {
                presentationMode.wrappedValue.dismiss()
              }
            }
        )
    }
  }
}

// Extension to make it easier to use
extension View {
  func enableSwipeBack() -> some View {
    modifier(SwipeBackModifier())
  }
}
