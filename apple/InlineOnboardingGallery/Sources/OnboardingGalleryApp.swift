import SwiftUI
import UIKit

@main
struct OnboardingGalleryApp: App {
  @StateObject private var session = OnboardingGallerySession()

  var body: some Scene {
    WindowGroup("iOS Onboarding") {
      OnboardingGalleryView(session: session)
        .onAppear {
          #if targetEnvironment(macCatalyst)
          for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 960, height: 760)
          }
          #endif
        }
    }
  }
}
