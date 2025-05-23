import Auth
import InlineKit
import Logger
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
    formState.startLoading()

    Task {
      do {
        let result = if !onboardingViewModel.email.isEmpty {
          try await ApiClient.shared.verifyCode(
            code: code,
            email: onboardingViewModel.email
          )
        } else if !onboardingViewModel.phoneNumber.isEmpty {
          try await ApiClient.shared.verifySmsCode(
            code: code,
            phoneNumber: onboardingViewModel.phoneNumber
          )
        } else {
          throw APIError.error(error: "INVALID_REQUEST", errorCode: 401, description: "Email and phone empty")
        }

        // Save creds
        await Auth.shared.saveCredentials(token: result.token, userId: result.userId)

        // Change passphrase of database
        try await AppDatabase.authenticated()

        // Save user
        do {
          let _ = try await AppDatabase.shared.dbWriter.write { db in
            try result.user.saveFull(db)
          }
        } catch {
          Log.shared.error("Failed to save user", error: error)
        }

        DispatchQueue.main.async {
          // Navigate
          if result.user.firstName == nil {
            onboardingViewModel.navigate(to: .profile)
          } else {
            onboardingViewModel.navigateAfterLogin()
          }
        }
      } catch {
        formState.failed(error: "Failed: \(error.localizedDescription)")
        Log.shared.error("Failed to send code", error: error)
      }
    }
  }
}

#Preview {
  OnboardingEnterCode()
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
