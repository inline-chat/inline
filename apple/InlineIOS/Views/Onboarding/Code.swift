import InlineKit
import SwiftUI

struct Code: View {
    var email: String
    @State private var code = ""
    @State var animate: Bool = false
    @FocusState private var isFocused: Bool
    @State var errorMsg: String = ""
    @FormState var formState
    @State private var isInputValid: Bool = false

    private var placeHolder: String = "xxxxxx"
    let characterLimit = 6

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient
    @EnvironmentObject var userData: UserData
    @Environment(\.appDatabase) var database

    init(email: String) {
        self.email = email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AnimatedLabel(animate: $animate, text: "Enter the code")
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
                .onChange(of: isFocused) { _, newValue in
                    withAnimation(.smooth(duration: 0.15)) {
                        animate = newValue
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
            Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
        }
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading) {
                HStack(spacing: 2) {
                    Text("Code sent to \(email).")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Edit") {
                        nav.push(.email(prevEmail: email))
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
        .onAppear {
            isFocused = true
        }
    }

    private func validateInput() {
        errorMsg = ""
        isInputValid = code.count == characterLimit
    }

    func submitCode() {
        Task {
            do {
                formState.startLoading()
                let result = try await api.verifyCode(code: code, email: email)

                Auth.shared.saveToken(result.token)
                Auth.shared.saveCurrentUserId(userId: result.userId)

                do {
                    try await AppDatabase.authenticated()
                } catch {
                    Log.shared.error("Failed to setup database or save user", error: error)
                }

                try await database.dbWriter.write { db in
                    let user = User(
                        id: result.userId,
                        email: email,
                        firstName: "",
                        lastName: nil
                    )
                    try user.save(db)
                }

                formState.reset()
                nav.push(.addAccount)

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

#Preview {
    Code(email: "dena@noor.to")
}
