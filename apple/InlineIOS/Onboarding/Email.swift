import InlineKit
import SwiftUI

struct Email: View {
  var prevEmail: String?
  @State private var email = ""
  @FocusState private var isFocused: Bool
  @State private var animate: Bool = false
  @State var errorMsg: String = ""
  @FormState var formState
  @State private var isInputValid: Bool = false

  private var placeHolder: String = NSLocalizedString("name@example.com", comment: "Email placeholder")

  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject var api: ApiClient

  init(prevEmail: String? = nil) {
    self.prevEmail = prevEmail
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      AnimatedLabel(animate: $animate, text: NSLocalizedString("Enter your email", comment: "Email input label"))
      TextField(placeHolder, text: $email)
        .focused($isFocused)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.vertical, 8)
        .onSubmit {
          submit()
        }
        .onChange(of: isFocused) { _, newValue in
          withAnimation(.smooth(duration: 0.15)) {
            animate = newValue
          }
        }
        .onChange(of: isInputValid) {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation {
              isInputValid = true
            }
          }
        }
      Text(errorMsg)
        .font(.callout)
        .foregroundColor(.red)
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
      .disabled(!isInputValid || formState.isLoading)
      .opacity((!isInputValid || formState.isLoading) ? 0.5 : 1)
    }
    .onAppear {
      if let prevEmail {
        email = prevEmail
      }
      isFocused = true
      validateInput()
    }
    .onChange(of: email) { _, _ in
      validateInput()
    }
  }

  private let emailRegex =
    #"(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9]))\.){3}(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9])|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])"#

  private func validateInput() {
    errorMsg = ""
    let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
    isInputValid = !email.isEmpty && emailPredicate.evaluate(with: email)
  }

  func submit() {
    Task {
      do {
        formState.startLoading()
        let _ = try await api.sendCode(email: email)
        formState.reset()
        nav.push(.code(email: email))
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg, isEmail: true)
        formState.reset()
        isInputValid = false
      }
    }
  }
}

#Preview {
  Email()
}
