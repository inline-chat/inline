import SwiftUI

extension View {
  func inlineSheetStyle() -> some View {
    presentationCornerRadius(12)
      .presentationBackground(.thinMaterial)
      .presentationBackgroundInteraction(.enabled)
  }
}
