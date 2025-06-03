import InlineKit
import SwiftUI

struct PhoneNumber: View {
  var prevPhoneNumber: String?
  @State private var phoneNumber = ""
  @State private var selectedCountry = Country.getCurrentCountry()
  @FocusState private var isFocused: Bool
  @State private var animate: Bool = false
  @State var errorMsg: String = ""
  @FormState var formState

  private let minPhoneLength = 10

  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject var api: ApiClient

  init(prevPhoneNumber: String? = nil) {
    self.prevPhoneNumber = prevPhoneNumber
  }

  var body: some View {
    VStack(spacing: 20) {
      Spacer()

      // Icon and title section
      VStack(spacing: 12) {
        Image(systemName: "phone.fill")
          .resizable()
          .scaledToFit()
          .frame(width: 34, height: 34)
          .foregroundColor(.primary)

        Text(NSLocalizedString("Sign in with phone", comment: "Phone sign in title"))
          .font(.system(size: 21.0, weight: .semibold))
          .foregroundStyle(.primary)
      }

      // Phone input field
      VStack(spacing: 8) {
        PhoneNumberField(phoneNumber: $phoneNumber, country: $selectedCountry)
          .focused($isFocused)
          .onSubmit {
            submit()
          }

        if !errorMsg.isEmpty {
          Text(errorMsg)
            .font(.callout)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, OnboardingUtils.shared.hPadding)

      Spacer()
    }
    .safeAreaInset(edge: .bottom) {
      Button(
        formState
          .isLoading ? NSLocalizedString("Sending Code...", comment: "Sending code button loading state") :
          NSLocalizedString("Continue", comment: "Continue button")
      ) {
        submit()
      }
      .buttonStyle(SimpleButtonStyle())
      .frame(maxWidth: .infinity)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
      .disabled(phoneNumber.count < minPhoneLength || formState.isLoading)
      .opacity((phoneNumber.count < minPhoneLength || formState.isLoading) ? 0.5 : 1)
    }
    .onAppear {
      if let prevPhoneNumber {
        // Parse the previous phone number to extract country and number
        parsePreviousPhoneNumber(prevPhoneNumber)
      }
      isFocused = true
    }
    .onChange(of: phoneNumber) { _, _ in
      // Clear error when user starts typing
      if !errorMsg.isEmpty {
        errorMsg = ""
      }
    }
  }

  func parsePreviousPhoneNumber(_ fullNumber: String) {
    // Try to find matching country by dial code
    for country in Country.allCountries {
      if fullNumber.hasPrefix(country.dialCode) {
        selectedCountry = country
        phoneNumber = String(fullNumber.dropFirst(country.dialCode.count))
        return
      }
    }
    // If no match found, just use the full number
    phoneNumber = fullNumber
  }

  func submit() {
    if phoneNumber.count < minPhoneLength {
      errorMsg = String(
        format: NSLocalizedString("Phone number must be at least %d digits.", comment: "Phone number validation error"),
        minPhoneLength
      )
      return
    }
    errorMsg = ""

    let fullPhoneNumber = selectedCountry.dialCode + phoneNumber

    Task {
      do {
        formState.startLoading()
        let result = try await api.sendSmsCode(phoneNumber: fullPhoneNumber)

        print("result is \(result)")
        formState.reset()
        nav.push(.phoneNumberCode(phoneNumber: fullPhoneNumber))
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg, isPhoneNumber: true)
        formState.reset()
      }
    }
  }
}

#Preview("PhoneNumber - Light Mode") {
  PhoneNumber()
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}

#Preview("PhoneNumber - Dark Mode") {
  PhoneNumber()
    .preferredColorScheme(.dark)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}

#Preview("PhoneNumber - With Previous Number") {
  PhoneNumber(prevPhoneNumber: "+15555555555")
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}

#Preview("PhoneNumber - Different Country") {
  @Previewable @State var phoneNumber = ""
  @Previewable @State var selectedCountry = Country.allCountries.first { $0.code == "GB" } ?? Country
    .getCurrentCountry()

  PhoneNumber()
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}
