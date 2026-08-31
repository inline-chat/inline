import SwiftUI

/// Presentation state only; this target does not link InlineKit, Auth, or RealtimeV2.
@MainActor
final class OnboardingGalleryProviderState: ObservableObject {
  @Published var errorMessage: String?
  @Published var isRedeeming = false
  @Published var showBrowserNotice = false

  func clearError() {
    errorMessage = nil
  }

  func showBrowserPreviewNotice() {
    showBrowserNotice = true
  }

  func reset() {
    errorMessage = nil
    isRedeeming = false
    showBrowserNotice = false
  }
}

@MainActor
final class OnboardingGallerySession: ObservableObject {
  nonisolated static let userID: Int64 = 1
  nonisolated static let email = "alex@example.com"
  nonisolated static let phone = "+14155550100"

  let navigation = OnboardingNavigation()
  let provider = OnboardingGalleryProviderState()
  @Published var selectedPage: OnboardingGalleryPage = .welcome
  @Published var previewID = UUID()
  @Published var didFinish = false

  init() {
    // Seed the identity scope before constructing any profile view.
    navigation.prepareProfileDraft(for: Self.userID)
  }

  func show(_ page: OnboardingGalleryPage) {
    provider.reset()
    didFinish = false
    navigation.reset()
    navigation.prepareProfileDraft(for: Self.userID)
    selectedPage = page
    navigation.path = page.path
    previewID = UUID()
  }
}
