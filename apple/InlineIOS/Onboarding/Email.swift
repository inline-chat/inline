import InlineKit
import SwiftUI

struct Email: View {
  var prevEmail: String?
  @State private var email = ""
  @FocusState private var isFocused: Bool
  @FormState var formState
  @State private var errorMsg: String = ""

  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject var api: ApiClient

  init(prevEmail: String? = nil) {
    self.prevEmail = prevEmail
  }

  var body: some View {
    VStack(spacing: 20) {
      Spacer()

      // Icon and title section
      VStack(spacing: 12) {
        Image(systemName: "at.circle.fill")
          .resizable()
          .scaledToFit()
          .frame(width: 34, height: 34)
          .foregroundColor(.primary)

        Text(NSLocalizedString("Sign in with email", comment: "Email sign in title"))
          .font(.system(size: 21.0, weight: .semibold))
          .foregroundStyle(.primary)
      }

      // Email input field
      VStack(spacing: 8) {
        TextField(NSLocalizedString("Your Email", comment: "Email input placeholder"), text: $email)
          .focused($isFocused)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .textContentType(.emailAddress)
          .font(.body)
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .background(
            RoundedRectangle(cornerRadius: 16)
              .fill(.ultraThinMaterial)
              .overlay(
                RoundedRectangle(cornerRadius: 16)
                  .stroke(
                    isFocused ? Color.accentColor : Color(.systemGray4),
                    lineWidth: isFocused ? 2 : 0.5
                  )
              )
          )
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .animation(.easeInOut(duration: 0.2), value: isFocused)
          .disabled(formState.isLoading)
          .onSubmit {
            sendCode()
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
        sendCode()
      }
      .buttonStyle(SimpleButtonStyle())
      .frame(maxWidth: .infinity)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
      .disabled(!isEmailValid || formState.isLoading)
      .opacity((!isEmailValid || formState.isLoading) ? 0.5 : 1)
    }
    .onAppear {
      if let prevEmail {
        email = prevEmail
      }
      isFocused = true
    }
  }

  private var isEmailValid: Bool {
    let emailRegex =
      #"(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9]))\.){3}(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9])|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])"#
    let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
    return !email.isEmpty && emailPredicate.evaluate(with: email)
  }

  func sendCode() {
    guard isEmailValid else { return }

    formState.startLoading()

    Task {
      do {
        let _ = try await api.sendCode(email: email)
        formState.reset()
        nav.push(.code(email: email))
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg, isEmail: true)
        formState.reset()
      } catch {
        errorMsg = error.localizedDescription
        formState.reset()
      }
    }
  }
}

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
