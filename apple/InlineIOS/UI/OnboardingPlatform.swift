import SwiftUI

extension Font {
  static var onboardingIOSTitle: Font {
    #if os(iOS)
    .title
    #else
    .system(size: 28)
    #endif
  }

  static var onboardingIOSTitle2: Font {
    #if os(iOS)
    .title2
    #else
    .system(size: 22)
    #endif
  }

  static var onboardingIOSBody: Font {
    #if os(iOS)
    .body
    #else
    .system(size: 17)
    #endif
  }

  static var onboardingIOSFootnote: Font {
    #if os(iOS)
    .footnote
    #else
    .system(size: 13)
    #endif
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
