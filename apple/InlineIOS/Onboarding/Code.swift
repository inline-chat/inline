import Auth
import GRDBQuery
import InlineKit
import Logger
import SwiftUI

struct Code: View {
  var email: String
  var placeHolder: String = "xxxxxx"
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
  @EnvironmentObject var ws: WebSocketManager
  @Environment(\.appDatabase) var database
  @Environment(\.auth) private var auth

  init(email: String) {
    self.email = email
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      AnimatedLabel(animate: $animate, text: "Enter the code")
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

extension Code {
  private func validateInput() {
    errorMsg = ""
    isInputValid = code.count == characterLimit
  }

  func submitCode() {
    Task {
      do {
        formState.startLoading()
        let result = try await api.verifyCode(code: code, email: email)

        await auth.saveCredentials(token: result.token, userId: result.userId)

        do {
          try await AppDatabase.authenticated()

          // Establish WebSocket connection
          ws.authenticated()
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
        errorMsg = "Please try again."
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

extension Code {
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
        Text("Code sent to \(email).")
          .font(.callout)
          .foregroundColor(.secondary)
        Button("Edit") {
          nav.pop()
        }
        .font(.callout)
      }

      Button(formState.isLoading ? "Verifying..." : "Continue") {
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
  Code(email: "dena@noor.to")
}
