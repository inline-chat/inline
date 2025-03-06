import SwiftUI

struct AnimatedDots: View {
  // MARK: - Customization Properties
    
  /// The number of dots to display (default: 3)
  var dotCount: Int = 3
    
  /// The size of each dot in points
  var dotSize: CGFloat = 4
    
  /// The spacing between dots
  var spacing: CGFloat = 2
    
  /// The color of the dots
  var dotColor: Color = .primary
    
  /// The minimum opacity during animation (0-1)
  var minOpacity: Double = 0.4
    
  /// The maximum opacity during animation (0-1)
  var maxOpacity: Double = 1.0
    
  /// The minimum scale during animation
  var minScale: CGFloat = 1.0
    
  /// The maximum scale during animation
  var maxScale: CGFloat = 1.3
    
  /// The duration of one complete animation cycle
  var animationDuration: Double = 0.8
    
  /// Whether to use scale animation
  var useScale: Bool = true
    
  /// Whether to use opacity animation
  var useOpacity: Bool = true
    
  // MARK: - Private State
    
  /// Tracks whether the component is currently displayed
  @State private var isVisible = false
    
  // MARK: - Body
    
  var body: some View {
    HStack(spacing: spacing) {
      ForEach(0 ..< dotCount, id: \.self) { index in
        Circle()
          .fill(dotColor)
          .frame(width: dotSize, height: dotSize)
          .modifier(DotAnimationModifier(
            isVisible: isVisible,
            index: index,
            dotCount: dotCount,
            minOpacity: minOpacity,
            maxOpacity: maxOpacity,
            minScale: minScale,
            maxScale: maxScale,
            duration: animationDuration,
            useScale: useScale,
            useOpacity: useOpacity
          ))
      }
    }
    .onAppear {
      isVisible = true
    }
    .onDisappear {
      isVisible = false
    }
  }
}

/// Modifier that handles the animation of individual dots
private struct DotAnimationModifier: ViewModifier {
  let isVisible: Bool
  let index: Int
  let dotCount: Int
  let minOpacity: Double
  let maxOpacity: Double
  let minScale: CGFloat
  let maxScale: CGFloat
  let duration: Double
  let useScale: Bool
  let useOpacity: Bool
    
  @State private var opacity: Double
  @State private var scale: CGFloat
    
  init(isVisible: Bool, index: Int, dotCount: Int, minOpacity: Double, maxOpacity: Double,
       minScale: CGFloat, maxScale: CGFloat, duration: Double, useScale: Bool, useOpacity: Bool)
  {
    self.isVisible = isVisible
    self.index = index
    self.dotCount = dotCount
    self.minOpacity = minOpacity
    self.maxOpacity = maxOpacity
    self.minScale = minScale
    self.maxScale = maxScale
    self.duration = duration
    self.useScale = useScale
    self.useOpacity = useOpacity
        
    // Initialize with starting values
    self._opacity = State(initialValue: minOpacity)
    self._scale = State(initialValue: minScale)
  }
    
  func body(content: Content) -> some View {
    content
      .opacity(useOpacity ? opacity : 1)
      .scaleEffect(useScale ? scale : 1)
      .onAppear {
        if isVisible {
          startAnimation()
        }
      }
      .onChange(of: isVisible) { newValue in
        if newValue {
          startAnimation()
        }
      }
  }
    
  private func startAnimation() {
    // Calculate delay based on index to create sequential animation
    let delay = (Double(index) / Double(dotCount)) * duration
        
    // Reset to initial state
    opacity = minOpacity
    scale = minScale
        
    // Wait for the calculated delay before starting animation
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      // Create infinite animation
      withAnimation(Animation.easeInOut(duration: duration / 2)
        .repeatForever(autoreverses: true))
      {
        opacity = maxOpacity
        scale = maxScale
      }
    }
  }
}

// MARK: - Preview

struct AnimatedDots_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 30) {
      // Default style
      AnimatedDots()
        .previewDisplayName("Default")
            
      // Custom style 1: Larger blue dots
      AnimatedDots(
        dotSize: 8,
        spacing: 4,
        dotColor: .blue,
        minOpacity: 0.3,
        maxOpacity: 1.0,
        minScale: 0.8,
        maxScale: 1.4
      )
      .previewDisplayName("Large Blue Dots")
            
      // Custom style 2: More dots, only opacity animation
      AnimatedDots(
        dotCount: 5,
        dotSize: 6,
        spacing: 3,
        dotColor: .red,
        useScale: false
      )
      .previewDisplayName("Five Red Dots")
            
      // Custom style 3: Only scale animation
      AnimatedDots(
        dotSize: 10,
        dotColor: .green,
        minScale: 0.7,
        maxScale: 1.0,
        useOpacity: false
      )
      .previewDisplayName("Green Scale Only")
    }
    .padding()
    .previewLayout(.sizeThatFits)
  }
}
