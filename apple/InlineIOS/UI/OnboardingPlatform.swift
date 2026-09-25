import SwiftUI

extension Font {
  static var onboardingIOSTitle: Font {
    .title
  }

  static var onboardingIOSTitle2: Font {
    .title2
  }

  static var onboardingIOSBody: Font {
    .body
  }

  static var onboardingIOSFootnote: Font {
    .footnote
  }
}

extension Color {
  static var onboardingSystemGray4: Color {
    #if os(iOS)
    Color(uiColor: .systemGray4)
    #else
    Color(nsColor: .systemGray)
    #endif
  }

  static var onboardingSystemGray6: Color {
    #if os(iOS)
    Color(uiColor: .systemGray6)
    #else
    Color(nsColor: .controlBackgroundColor)
    #endif
  }
}

extension View {
  @ViewBuilder
  func onboardingEmailInput() -> some View {
    #if os(iOS)
    keyboardType(.emailAddress)
      .textInputAutocapitalization(.never)
      .textContentType(.emailAddress)
      .multilineTextAlignment(.center)
    #else
    self
    #endif
  }

  @ViewBuilder
  func onboardingNumberInput() -> some View {
    #if os(iOS)
    keyboardType(.numberPad)
      .textInputAutocapitalization(.never)
    #else
    self
    #endif
  }
}
