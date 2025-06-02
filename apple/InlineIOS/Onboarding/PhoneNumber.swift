import InlineKit
import iPhoneNumberField
import SwiftUI

struct PhoneNumber: View {
  var prevPhoneNumber: String?
  @State private var phoneNumber = ""
  @FocusState private var isFocused: Bool
  @State private var animate: Bool = false
  @State var errorMsg: String = ""
  @FormState var formState

  private var placeHolder: String = NSLocalizedString("+1 555 555 5555", comment: "Phone number placeholder")
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
        iPhoneNumberField(placeHolder, text: $phoneNumber)
          .flagHidden(false)
          .flagSelectable(true)
          .prefixHidden(false)
          .focused($isFocused)
          .keyboardType(.phonePad)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .font(.body)
          .padding(.horizontal, 20)
          .padding(.vertical, 16)
          .background(
            RoundedRectangle(cornerRadius: 16)
              .fill(.ultraThinMaterial)
              .overlay(
                RoundedRectangle(cornerRadius: 16)
                  .stroke(Color(.systemGray4), lineWidth: 0.5)
              )
          )
          .clipShape(RoundedRectangle(cornerRadius: 16))
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
        phoneNumber = prevPhoneNumber
      }
      isFocused = true
    }
    .onChange(of: phoneNumber) { _, _ in
      // Removed validateInput()
    }
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
    Task {
      do {
        formState.startLoading()
        let result = try await api.sendSmsCode(phoneNumber: phoneNumber)

        print("result is \(result)")
        formState.reset()
        nav.push(.phoneNumberCode(phoneNumber: phoneNumber))
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg, isPhoneNumber: true)
        formState.reset()
      }
    }
  }
}

#Preview {
  PhoneNumber()
}
