import Auth
import GRDBQuery
import InlineKit
import Logger
import SwiftUI

struct PhoneNumberCode: View {
  var phoneNumber: String
  var placeHolder: String = NSLocalizedString("xxxxxx", comment: "Code input placeholder")
  let characterLimit = 6

  @State var code = ""
  @State var animate: Bool = false
  @State var errorMsg: String = ""
  @State var isInputValid: Bool = false

  @FocusState private var isFocused: Bool
  @FormState var formState

  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject var api: ApiClient
  @EnvironmentObject var userData: UserData
  @EnvironmentObject var mainViewRouter: MainViewRouter
  @Environment(\.appDatabase) var database
  @Environment(\.auth) private var auth
  @Environment(\.realtime) private var realtime

  init(phoneNumber: String) {
    self.phoneNumber = phoneNumber
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      AnimatedLabel(animate: $animate, text: NSLocalizedString("Enter the code", comment: "Code input label"))
      codeInput
      hint
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .safeAreaInset(edge: .bottom) {
      bottomArea
    }
    .onAppear {
      isFocused = true
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
    Task {
      do {
        formState.startLoading()
        let result = try await api.verifySmsCode(code: code, phoneNumber: phoneNumber)

        await auth.saveCredentials(token: result.token, userId: result.userId)

        do {
          try await AppDatabase.authenticated()
        } catch {
          Log.shared.error("Failed to setup database or save user", error: error)
        }

        let _ = try await database.dbWriter.write { db in
          try result.user.saveFull(db)
        }

        formState.reset()
        if result.user.firstName == nil || result.user.firstName?.isEmpty == true {
          nav.push(.profile)
        } else {
          mainViewRouter.setRoute(route: .main)
          nav.push(.main)
        }

      } catch let error as APIError {
        errorMsg = NSLocalizedString("Please try again.", comment: "Error message for code verification")
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
        isInputValid = false
      } catch {
        Log.shared.error("Unexpected error", error: error)
        formState.reset()
        isInputValid = false
      }
    }
  }
}

// MARK: - Views

extension PhoneNumberCode {
  @ViewBuilder
  var codeInput: some View {
    TextField(placeHolder, text: $code)
      .focused($isFocused)
      .keyboardType(.numberPad)
      .textInputAutocapitalization(.never)
      .monospaced()
      .kerning(5)
      .autocorrectionDisabled(true)
      .font(.title2)
      .fontWeight(.semibold)
      .padding(.vertical, 8)
      .onSubmit {
        submitCode()
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
  var hint: some View {
    Text(errorMsg)
      .font(.callout)
      .foregroundColor(.red)
  }

  @ViewBuilder
  var bottomArea: some View {
    VStack(alignment: .center) {
      HStack(spacing: 2) {
        Text(String(format: NSLocalizedString("Code sent to %@.", comment: "Code sent confirmation"), phoneNumber))
          .font(.callout)
          .foregroundColor(.secondary)
        Button(NSLocalizedString("Edit", comment: "Edit button")) {
          nav.pop()
        }
        .font(.callout)
      }

      Button(
        formState
          .isLoading ? NSLocalizedString("Verifying...", comment: "Verifying code button loading state") :
          NSLocalizedString("Continue", comment: "Continue button")
      ) {
        submitCode()
      }
      .buttonStyle(SimpleButtonStyle())
      .frame(maxWidth: .infinity)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
      .disabled(!isInputValid || formState.isLoading)
      .opacity((!isInputValid || formState.isLoading) ? 0.5 : 1)
    }
  }
}

#Preview {
  PhoneNumberCode(phoneNumber: "+15555555555")
}
