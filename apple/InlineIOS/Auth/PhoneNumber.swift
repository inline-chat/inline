#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
import Logger
#endif
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

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject var nav: OnboardingNavigation
  #if !IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject var api: ApiClient
  #endif

  init(prevPhoneNumber: String? = nil) {
    self.prevPhoneNumber = prevPhoneNumber
  }

  var body: some View {
    OnboardingFormPage(focus: $isFocused) {
      // Icon and title section
      OnboardingFormHeader(
        title: Text(NSLocalizedString("Continue with phone", comment: "Phone sign in title")),
        systemImage: "checkmark.message"
      )

      // Phone input field
      VStack(spacing: 8) {
        PhoneNumberField(phoneNumber: $phoneNumber, country: $selectedCountry, focus: $isFocused)
          .onSubmit {
            submit()
          }

        if !errorMsg.isEmpty {
          Text(errorMsg)
            .font(.callout)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .contentTransition(.opacity)
            .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: errorMsg)
    } actions: {
      Button(
        formState
          .isLoading ? NSLocalizedString("Sending Code...", comment: "Sending code button loading state") :
          NSLocalizedString("Continue", comment: "Continue button")
      ) {
        submit()
      }
      .buttonStyle(OnboardingFormButtonStyle())
      .disabled(phoneNumber.count < minPhoneLength || formState.isLoading)
    }
    .onAppear {
      if let prevPhoneNumber {
        // Parse the previous phone number to extract country and number
        parsePreviousPhoneNumber(prevPhoneNumber)
      }
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
    guard !formState.isLoading else { return }
    if phoneNumber.count < minPhoneLength {
      errorMsg = String(
        format: NSLocalizedString("Phone number must be at least %d digits.", comment: "Phone number validation error"),
        minPhoneLength
      )
      return
    }
    errorMsg = ""

    let fullPhoneNumber = selectedCountry.dialCode + phoneNumber

    #if IOS_ONBOARDING_GALLERY_APP
    nav.push(.phoneNumberCode(phoneNumber: fullPhoneNumber))
    #else
    formState.startLoading()
    Task {
      do {
        let result = try await api.sendSmsCode(phoneNumber: fullPhoneNumber)

        Log.shared.debug("result is \(result)")
        formState.reset()
        nav.existingUser = result.existingUser
        if result.needsInviteCode == true {
          nav.push(.inviteCodeForPhone(phoneNumber: fullPhoneNumber))
        } else {
          nav.push(.phoneNumberCode(phoneNumber: fullPhoneNumber))
        }
      } catch is CancellationError {
        formState.reset()
      } catch {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
      } catch {
        errorMsg = InlineProtocolNativeLogin.userFacingMessage(for: error)
        formState.reset()
      }
    }
    #endif
  }
}

#if !IOS_ONBOARDING_GALLERY_APP
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
#endif
