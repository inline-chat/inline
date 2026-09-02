import Auth
import InlineKit
import InlineMacUI
import Logger
import Sentry
import SwiftUI

struct OnboardingEnterCode: View {
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel
  @FormState var formState
  @State var code = ""

  enum Field {
    case codeField
  }

  @FocusState private var focusedField: Field?

  let codeLimit = 6

  var buttonLabel: String {
    switch onboardingViewModel.existingUser {
    case .none:
      "Continue"
    case .some(true):
      "Log In"
    case .some(false):
      "Sign Up"
    }
  }

  var body: some View {
    VStack {
      Image(systemName: "numbers.rectangle.fill")
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
        .foregroundColor(.primary)
        .padding(.bottom, 4)

      Text("Enter confirmation code")
        .font(.system(size: 21.0, weight: .semibold))
        .foregroundStyle(.primary)

      emailField
        .focused($focusedField, equals: .codeField)
        .disabled(formState.isLoading)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .onSubmit {
          submit()
        }
        .onChange(of: code) { newCode in
          code = newCode.filter(\.isNumber)

          // Auto-submit
          if code.count == codeLimit, !formState.isLoading {
            submit()
          }
        }
        .onAppear {
          focusedField = .codeField
        }

      if let error = formState.error {
        Text(error)
          .font(.callout)
          .foregroundColor(.red)
          .multilineTextAlignment(.center)
          .frame(width: 260)
          .padding(.bottom, 8)
      }

      InlineButton {
        submit()
      } label: {
        if !formState.isLoading {
          Text(buttonLabel).padding(.horizontal)
        } else {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(0.5)
        }
      }
      .disabled(formState.isLoading)
    }
    .padding()
  }

  @ViewBuilder var emailField: some View {
    let view =
      GrayTextField("Code", text: $code, prompt: Text("123654"))
        .frame(width: 260)

    if #available(macOS 14.0, *) {
      view
        .textContentType(.oneTimeCode)
    } else {
      view
    }
  }

  func submit() {
    guard !formState.isLoading else { return }
    formState.startLoading()

    Task {
      do {
        let bearerLoginAttempt = InlineProtocolNativeLogin.shared.isAvailable
          ? nil
          : try await Auth.shared.beginLoginAttempt()
        let result = if !onboardingViewModel.email.isEmpty {
          try await ApiClient.shared.verifyCode(
            code: code,
            email: onboardingViewModel.email,
            challengeToken: onboardingViewModel.emailChallengeToken,
            inviteCode: onboardingViewModel.inviteCode
          )
        } else if !onboardingViewModel.phoneNumber.isEmpty {
          try await ApiClient.shared.verifySmsCode(
            code: code,
            phoneNumber: onboardingViewModel.phoneNumber,
            inviteCode: onboardingViewModel.inviteCode
          )
        } else {
          throw APIError.error(error: "INVALID_REQUEST", errorCode: 401, description: "Email and phone empty")
        }

        let accountMutationToken: AuthAccountMutationToken
        if let token = result.token {
          do {
            guard let loginAttempt = bearerLoginAttempt else {
              throw AuthStorageError.loginSuperseded
            }
            let commit = try await LoginStatePreparation.commit(
              loginAttempt: loginAttempt,
              targetUserID: result.userId,
              persistCredentials: {
                try await Auth.shared.saveCredentials(
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

        try Auth.shared.handle.validateAccountMutation(accountMutationToken)
        // Register Sentry
        Analytics.identify(
          userId: result.userId,
          email: result.user.email,
          name: result.user.anyName,
          username: result.user.username
        )

        await MainActor.run {
          guard (try? Auth.shared.handle.validateAccountMutation(accountMutationToken)) != nil else {
            return
          }
          AppSettings.shared.resolveSidebarModeForAccount(
            createdAt: Date(timeIntervalSince1970: TimeInterval(result.user.date))
          )
          GettingStartedVisibility.prepare(
            for: result.userId,
            isNewSignup: onboardingViewModel.existingUser == false
          )
        }

        DispatchQueue.main.async {
          guard (try? Auth.shared.handle.validateAccountMutation(accountMutationToken)) != nil else {
            return
          }
          onboardingViewModel.navigateAfterLogin(pendingSetup: result.user.pendingSetup == true)
        }
      } catch InlineProtocolNativeLoginError.inviteRequired {
        formState.reset()
        onboardingViewModel.navigate(to: .inviteCode)
      } catch is CancellationError {
        formState.reset()
      } catch {
        formState.failed(error: error.localizedDescription)
        Log.shared.error("Failed to complete sign-in", error: error)
      }
    }
  }
}

#Preview {
  OnboardingEnterCode()
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
