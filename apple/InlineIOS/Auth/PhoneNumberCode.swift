#if !IOS_ONBOARDING_GALLERY_APP
import Auth
import GRDBQuery
import InlineKit
import Logger
#endif
import SwiftUI

struct PhoneNumberCode: View {
  var phoneNumber: String
  var inviteCode: String?
  var placeHolder: String = NSLocalizedString("xxxxxx", comment: "Code input placeholder")
  let characterLimit = 6

  @State var code = ""
  @State var animate: Bool = false
  @State var errorMsg: String = ""
  @State var isInputValid: Bool = false

  @FocusState private var isFocused: Bool
  @FormState var formState

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject var nav: OnboardingNavigation
  #if !IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject var api: ApiClient
  @EnvironmentObject var userData: UserData
  @EnvironmentObject var mainViewRouter: MainViewRouter
  @Environment(\.appDatabase) var database
  @Environment(\.auth) private var auth
  @Environment(\.realtime) private var realtime
  #endif

  init(phoneNumber: String, inviteCode: String? = nil) {
    self.phoneNumber = phoneNumber
    self.inviteCode = inviteCode
  }

  var body: some View {
    OnboardingFormPage(focus: $isFocused) {
      // Icon and title section
      OnboardingFormHeader(
        title: Text(NSLocalizedString("Enter confirmation code", comment: "Code input title")),
        systemImage: "numbers.rectangle"
      )

      // Code input field
      VStack(spacing: 8) {
        codeInput

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
      bottomArea
    }
  }
}

// MARK: - Helper Methods

extension PhoneNumberCode {
  private func validateInput() {
    errorMsg = ""
    isInputValid = code.count == characterLimit
  }

  func submitCode() {
    guard !formState.isLoading else { return }
    guard code.count == characterLimit else {
      errorMsg = String(localized: "Enter the 6-digit code.")
      return
    }
    errorMsg = ""
    #if IOS_ONBOARDING_GALLERY_APP
    nav.push(.profile(userId: OnboardingGallerySession.userID))
    #else
    formState.startLoading()
    Task {
      do {
        let bearerLoginAttempt = InlineProtocolNativeLogin.shared.isAvailable
          ? nil
          : try await auth.beginLoginAttempt()
        let result = try await api.verifySmsCode(code: code, phoneNumber: phoneNumber, inviteCode: inviteCode)

        let accountMutationToken: AuthAccountMutationToken
        if let token = result.token {
          do {
            guard let loginAttempt = bearerLoginAttempt else {
              throw AuthStorageError.loginSuperseded
            }
            let commit = try await LoginStatePreparation.commit(
              auth: auth.handle,
              loginAttempt: loginAttempt,
              targetUserID: result.userId,
              persistCredentials: {
                try await auth.saveCredentials(
                  token: token,
                  userId: result.userId,
                  loginAttempt: loginAttempt
                )
              }
            ) { db in
              try result.user.saveFull(db)
            }
            accountMutationToken = commit.accountMutationToken
          } catch {
            _ = try? await ApiClient.shared.logout(bearerToken: token)
            throw error
          }
        } else if let nativeToken = result.accountMutationToken {
          accountMutationToken = nativeToken
        } else {
          throw AuthStorageError.loginSuperseded
        }

        try auth.handle.validateAccountMutation(accountMutationToken)
        // Register Sentry
        Analytics.identify(
          userId: result.userId,
          email: result.user.email,
          name: result.user.anyName,
          username: result.user.username
        )

        formState.reset()
        try auth.handle.validateAccountMutation(accountMutationToken)
        if result.user.firstName == nil || result.user.firstName?.isEmpty == true || result.user.pendingSetup == true {
          nav.push(.profile(userId: result.userId))
        } else {
          nav.reset()
          mainViewRouter.setRoute(route: .main)
        }

      } catch InlineProtocolNativeLoginError.inviteRequired {
        formState.reset()
        nav.push(.inviteCodeForPhone(phoneNumber: phoneNumber))
      } catch is CancellationError {
        formState.reset()
      } catch {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
        isFocused = true
      }
    }
    #endif
  }
}

// MARK: - Views

extension PhoneNumberCode {
  @ViewBuilder
  var codeInput: some View {
    TextField(placeHolder, text: $code)
      .focused($isFocused)
      .onboardingNumberInput()
      .monospaced()
      .kerning(5)
      .autocorrectionDisabled(true)
      .multilineTextAlignment(.center)
      .onboardingFormField()
      .disabled(formState.isLoading)
      .onSubmit {
        submitCode()
      }
      .onChange(of: code) { _, newValue in
        if newValue.count > characterLimit {
          code = String(newValue.prefix(characterLimit))
        }
        validateInput()
        if newValue.count == characterLimit {
          submitCode()
        }
      }
  }

  @ViewBuilder
  var bottomArea: some View {
    VStack(alignment: .center, spacing: 12) {
      HStack(spacing: 2) {
        Text(String(format: NSLocalizedString("Code sent to %@.", comment: "Code sent confirmation"), phoneNumber))
          .font(.callout)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
        Button(NSLocalizedString("Edit", comment: "Edit button")) {
          nav.pop()
        }
        .font(.callout)
      }

      Button(
        formState
          .isLoading ? NSLocalizedString("Verifying...", comment: "Verifying code button loading state") :
          errorMsg.isEmpty ? NSLocalizedString("Continue", comment: "Continue button") :
          NSLocalizedString("Try Again", comment: "Retry code verification button")
      ) {
        submitCode()
      }
      .buttonStyle(OnboardingFormButtonStyle())
      .disabled(!isInputValid || formState.isLoading)
    }
  }
}

#if !IOS_ONBOARDING_GALLERY_APP
#Preview("PhoneNumberCode - Light Mode") {
  PhoneNumberCode(phoneNumber: "+15555555555")
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("PhoneNumberCode - Dark Mode") {
  PhoneNumberCode(phoneNumber: "+15555555555")
    .preferredColorScheme(.dark)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("PhoneNumberCode - International") {
  PhoneNumberCode(phoneNumber: "+447911123456")
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("PhoneNumberCode - Long Number") {
  PhoneNumberCode(phoneNumber: "+33123456789012")
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("PhoneNumberCode - Compact") {
  PhoneNumberCode(phoneNumber: "+15555555555")
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
    .previewDevice("iPhone SE (3rd generation)")
}
#endif
