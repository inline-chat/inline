#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif
import SwiftUI

struct InviteCode: View {
  enum Destination: Hashable {
    case email(email: String, challengeToken: String?)
    case phone(phoneNumber: String)
    case nativeApple
  }

  let destination: Destination

  @State private var code = ""
  @State private var errorMsg = ""
  @State private var isChecking = false
  @FocusState private var isFocused: Bool
  @EnvironmentObject var nav: OnboardingNavigation
  #if !IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject var api: ApiClient
  @ObservedObject private var providerSignIn = ProviderSignInCoordinator.shared
  #endif

  private var normalizedCode: String {
    code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private var isInputValid: Bool {
    normalizedCode.count == 8
  }

  var body: some View {
    OnboardingFormPage(focus: $isFocused) {
      VStack(spacing: 12) {
        OnboardingFormHeader(
          title: Text("Enter access invite code", comment: "Access invite code input title"),
          systemImage: "ticket"
        )

        Text(inviteDescription)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
      }

      VStack(spacing: 8) {
        codeInput

        if !errorMsg.isEmpty {
          Text(errorMsg)
            .font(.callout)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
        }
      }
    } actions: {
      Button(isChecking ? NSLocalizedString("Checking...", comment: "Checking invite code button loading state") : NSLocalizedString("Continue", comment: "Continue button")) {
        submit()
      }
      .buttonStyle(OnboardingFormButtonStyle())
      .disabled(!isInputValid || isChecking)
    }
  }

  @ViewBuilder
  var codeInput: some View {
    TextField("Access invite code", text: $code)
      .focused($isFocused)
      .textInputAutocapitalization(.characters)
      .autocorrectionDisabled(true)
      .monospaced()
      .multilineTextAlignment(.center)
      .onboardingFormField()
      .onSubmit {
        submit()
      }
      .onChange(of: code) { _, newValue in
        code = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        errorMsg = ""
      }
  }

  func submit() {
    guard isInputValid, !isChecking else {
      errorMsg = String(
        localized: "Enter the 8-character access invite code.",
        comment: "Access invite code validation error"
      )
      return
    }

    #if IOS_ONBOARDING_GALLERY_APP
    errorMsg = ""
    switch destination {
      case let .email(email, challengeToken):
        nav.push(.code(email: email, challengeToken: challengeToken, inviteCode: normalizedCode))
      case let .phone(phoneNumber):
        nav.push(.phoneNumberCode(phoneNumber: phoneNumber, inviteCode: normalizedCode))
      case .nativeApple:
        nav.push(.profile(userId: OnboardingGallerySession.userID))
    }
    #else
    isChecking = true
    errorMsg = ""

    Task {
      do {
        if case .nativeApple = destination {
          await providerSignIn.continueNativeAppleAuthorization(inviteCode: normalizedCode)
          isChecking = false
          if let error = providerSignIn.errorMessage { errorMsg = error }
          return
        }
        _ = try await api.checkInviteCode(normalizedCode)
        isChecking = false
        switch destination {
        case let .email(email, challengeToken):
          nav.push(.code(email: email, challengeToken: challengeToken, inviteCode: normalizedCode))
        case let .phone(phoneNumber):
          nav.push(.phoneNumberCode(phoneNumber: phoneNumber, inviteCode: normalizedCode))
        case .nativeApple:
          break
        }
      } catch let error as APIError {
        isChecking = false
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
      } catch {
        isChecking = false
        errorMsg = error.localizedDescription
      }
    }
    #endif
  }

  private var inviteDescription: LocalizedStringKey {
    switch destination {
      case .nativeApple:
        "Your Apple Account is verified. Enter an Inline invite code to create your account."
      case .email, .phone:
        "Your access invite code is separate from the verification code sent to your email or phone."
    }
  }
}

#if !IOS_ONBOARDING_GALLERY_APP
#Preview("Invite Code") {
  InviteCode(destination: .email(email: "user@example.com", challengeToken: nil))
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
}
#endif
