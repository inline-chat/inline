import SwiftUI
import UIKit

/// A separate hosting boundary keeps iOS navigation and appearance inside the phone canvas.
struct OnboardingGalleryPreview: UIViewControllerRepresentable {
  let navigation: OnboardingNavigation
  let session: OnboardingGallerySession
  let provider: OnboardingGalleryProviderState
  let colorScheme: ColorScheme

  func makeUIViewController(context: Context) -> UIHostingController<OnboardingGalleryPreviewRoot> {
    let controller = UIHostingController(rootView: root)
    controller.safeAreaRegions = []
    controller.traitOverrides.horizontalSizeClass = .compact
    controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    return controller
  }

  func updateUIViewController(_ controller: UIHostingController<OnboardingGalleryPreviewRoot>, context: Context) {
    controller.rootView = root
    controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
  }

  private var root: OnboardingGalleryPreviewRoot {
    OnboardingGalleryPreviewRoot(
      navigation: navigation,
      session: session,
      provider: provider,
      colorScheme: colorScheme
    )
  }
}

struct OnboardingGalleryPreviewRoot: View {
  let navigation: OnboardingNavigation
  let session: OnboardingGallerySession
  let provider: OnboardingGalleryProviderState
  let colorScheme: ColorScheme

  var body: some View {
    OnboardingView()
      .environmentObject(navigation)
      .environmentObject(session)
      .environmentObject(provider)
      .environment(\.horizontalSizeClass, .compact)
      .environment(\.colorScheme, colorScheme)
  }
}
