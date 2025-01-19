import SwiftUI
import InlineKit

public extension View {
  func previewsEnvironmentForMac(_ preset: PreviewsEnvironemntPreset) -> some View {
    return self
      .previewsEnvironment(preset)
      .environmentObject(MainWindowViewModel())
      .environmentObject(NavigationModel())
      .environmentObject(OverlayManager())
  }
}
