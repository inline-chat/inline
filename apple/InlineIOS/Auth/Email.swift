#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif
import SwiftUI

struct Email: View {
  var prevEmail: String?
  @State private var email = ""
  @FocusState private var isFocused: Bool
  @FormState var formState
  @State private var errorMsg: String = ""

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject var nav: OnboardingNavigation
  #if !IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject var api: ApiClient
  #endif

  init(prevEmail: String? = nil) {
    self.prevEmail = prevEmail
  }

  var body: some View {
    OnboardingFormPage(focus: $isFocused) {
      // Icon and title section
      OnboardingFormHeader(
        title: Text(NSLocalizedString("Sign in with email", comment: "Email sign in title")),
        systemImage: "at"
      )
      emailField
    } actions: {
      continueButton
        .disabled(formState.isLoading)
    }
    .onAppear {
      if let prevEmail {
        email = prevEmail
      }
    }
  }

  // Email input field
  private var emailField: some View {
    VStack(spacing: 8) {
      TextField(NSLocalizedString("Your Email", comment: "Email input placeholder"), text: $email)
        .focused($isFocused)
        .onboardingEmailInput()
        .autocorrectionDisabled(true)
        .onboardingFormField()
        .disabled(formState.isLoading)
        .onSubmit {
          sendCode()
        }
        .onChange(of: email) { _, _ in
          if !errorMsg.isEmpty {
            errorMsg = ""
          }
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
  }

  private var continueButton: some View {
    Button {
      sendCode()
    } label: {
      Text(
        formState
          .isLoading ? NSLocalizedString("Sending Code...", comment: "Sending code button loading state") :
          NSLocalizedString("Continue", comment: "Continue button")
      )
    }
    .buttonStyle(OnboardingFormButtonStyle())
  }

  func sendCode() {
    guard !formState.isLoading else { return }
    errorMsg = ""
    #if IOS_ONBOARDING_GALLERY_APP
    guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorMsg = "Enter an email address to preview the next page."
      return
    }
    nav.push(.code(email: email))
    #else
    formState.startLoading()

    Task {
      do {
        let response = try await api.sendCode(email: email)
        formState.reset()
        nav.existingUser = response.existingUser
        if response.needsInviteCode == true {
          nav.push(.inviteCodeForEmail(email: email, challengeToken: response.challengeToken))
        } else {
          nav.push(.code(email: email, challengeToken: response.challengeToken))
        }
      } catch is CancellationError {
        formState.reset()
      } catch {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
      }
    }
    #endif
  }
}

#if !IOS_ONBOARDING_GALLERY_APP
#Preview("Email - Light Mode") {
  Email()
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}

#Preview("Email - Dark Mode") {
  Email()
    .preferredColorScheme(.dark)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}

#Preview("Email - With Previous Email") {
  Email(prevEmail: "user@example.com")
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}

#Preview("Email - Error State") {
  Email()
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}
#endif
