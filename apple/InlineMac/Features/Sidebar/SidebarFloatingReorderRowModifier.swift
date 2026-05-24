import SwiftUI

struct SidebarFloatingReorderRowModifier: ViewModifier {
  let enabled: Bool
  let isDragging: Bool
  let onDragChanged: (DragGesture.Value, CGSize) -> Void
  let onDragEnded: () -> Void

  @State private var rowSize: CGSize = .zero

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      content
        .opacity(isDragging ? 0 : 1)
        .background {
          GeometryReader { proxy in
            Color.clear
              .onAppear {
                rowSize = proxy.size
              }
              .onChange(of: proxy.size) { _, size in
                rowSize = size
              }
          }
        }
        .simultaneousGesture(dragGesture)
    } else {
      content
    }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { value in
        onDragChanged(value, rowSize)
      }
      .onEnded { _ in
        onDragEnded()
      }
  }
}
