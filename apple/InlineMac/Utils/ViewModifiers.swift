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
}
