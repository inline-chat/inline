import Foundation
import SwiftUI

extension View {
  // Use for macOS checks in view modifiers
  @ViewBuilder
  func conditional<Content: View>(_ content: @escaping (Self) -> Content?) -> some View {
    if let out = content(self) {
      out
    } else {
      self
    }
  }

  /// Applies the given transform if the given condition evaluates to `true`.
  /// - Parameters:
  ///   - condition: The condition to evaluate.
  ///   - transform: The transform to apply to the source `View`.
  /// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
  @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }

  // Use for checking width of the view
  @ViewBuilder func onWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
    background(
      GeometryReader { reader in
        Color.clear
          .onChange(of: reader.frame(in: .global).width) { newValue in
            action(newValue)
          }
      }
    )
  }

  func eraseToAnyView() -> AnyView {
    AnyView(self)
  }
}
