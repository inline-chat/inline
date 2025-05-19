import SwiftUI

struct UploadProgressIndicator: View {
  @State private var width: CGFloat = 0
  @State private var offset: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  let color: Color

  init(color: Color = .primary) {
    self.color = color
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        // Background rectangle (rect2)
        RoundedRectangle(cornerRadius: 2)
          .fill(color.opacity(0.2))

        // Animated progress rectangle (rect1)
        RoundedRectangle(cornerRadius: 2)
          .fill(color.opacity(0.6))
          .frame(width: width)
          .offset(x: offset)
      }
      .onAppear {
        containerWidth = geometry.size.width
        startAnimation()
      }
    }
    .frame(height: 4)
  }

  private func startAnimation() {
    // Start with a small width and no offset
    width = 0
    offset = 0

    // Step 1: Expand to fill from left to right
    withAnimation(.easeInOut(duration: 0.5)) {
      width = containerWidth
    }

    // Step 2: Stay filled for a moment
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      // Step 3: Collapse from left to right
      withAnimation(.easeInOut(duration: 0.5)) {
        width = 0
        offset = containerWidth
      }
    }

    // Repeat the sequence
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
      // Reset position and expand
      offset = 0
      withAnimation(.easeInOut(duration: 0.5)) {
        width = containerWidth
      }

      // Stay filled then collapse
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        withAnimation(.easeInOut(duration: 0.5)) {
          width = 0
          offset = containerWidth
        }
      }
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    UploadProgressIndicator()
      .frame(width: 100)

    UploadProgressIndicator(color: .blue)
      .frame(width: 150)

    UploadProgressIndicator(color: .green)
      .frame(width: 200)
  }
  .padding()
}
