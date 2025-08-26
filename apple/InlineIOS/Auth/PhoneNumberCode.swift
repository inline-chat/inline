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
  @Environment(\.colorScheme) private var colorScheme

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

  private func buttonColor() -> Color {
    if colorScheme == .dark {
      Color(red: 0x8B / 255.0, green: 0x77 / 255.0, blue: 0xDC / 255.0)
    } else {
      Color(red: 0xA2 / 255.0, green: 0x8C / 255.0, blue: 0xF2 / 255.0)
    }
  }

  var body: some View {
    VStack(spacing: 20) {
      Spacer()

      // Icon and title section
      VStack(spacing: 12) {
        Image(systemName: "key.fill")
          .resizable()
          .scaledToFit()
          .frame(width: 34, height: 34)
          .foregroundColor(.primary)

        Text(NSLocalizedString("Enter the code", comment: "Code input title"))
          .font(.system(size: 21.0, weight: .semibold))
          .foregroundStyle(.primary)
      }

      // Code input field
      VStack(spacing: 8) {
        codeInput

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
        if result.user.firstName == nil || result.user.firstName?.isEmpty == true || result.user.pendingSetup == true {
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
      .multilineTextAlignment(.center)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                isFocused ? buttonColor() : Color(.systemGray4),
                lineWidth: isFocused ? 2 : 0.5
              )
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .animation(.easeInOut(duration: 0.2), value: isFocused)
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
