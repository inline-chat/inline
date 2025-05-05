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
  @State private var isInputValid: Bool = false

  private var placeHolder: String = "+1 555 555 5555"

  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject var api: ApiClient

  init(prevPhoneNumber: String? = nil) {
    self.prevPhoneNumber = prevPhoneNumber
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      AnimatedLabel(animate: $animate, text: "Enter your phone number")
      iPhoneNumberField("+0 0000 000000", text: $phoneNumber)
        .flagHidden(false)
        .flagSelectable(true)
        .prefixHidden(false)
        .focused($isFocused)
        .keyboardType(.phonePad)
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
      Button(formState.isLoading ? "Sending Code..." : "Continue") {
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
      if let prevPhoneNumber {
        phoneNumber = prevPhoneNumber
      }
      isFocused = true
      validateInput()
    }
    .onChange(of: phoneNumber) { _, _ in
      validateInput()
    }
  }

  private let phoneRegex = "^\\+?[1-9]\\d{1,14}$"
  private let minPhoneLength = 10 // Adjust as needed for your use case

  private func validateInput() {
    let phonePredicate = NSPredicate(format: "SELF MATCHES %@", phoneRegex)

    let digits = phoneNumber.filter(\.isNumber)
    isInputValid = !phoneNumber.isEmpty && phonePredicate.evaluate(with: phoneNumber) && digits.count >= minPhoneLength
  }

  func submit() {
    validateInput()
    if !isInputValid {
      OnboardingUtils.shared.showPhoneNumberError(errorMsg: $errorMsg)
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
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg, isEmail: false)
        formState.reset()
        isInputValid = false
      }
    }
  }
}

#Preview {
  PhoneNumber()
}
