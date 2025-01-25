import InlineKit
import SwiftUI

public extension View {
  func previewsEnvironmentForMac(_ preset: PreviewsEnvironemntPreset) -> some View {
    previewsEnvironment(preset)
      .environmentObject(MainWindowViewModel())
      .environmentObject(NavigationModel())
      .environmentObject(OverlayManager())
  }
}
