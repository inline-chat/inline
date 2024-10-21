import InlineKit
import SwiftUI

struct Code: View {
    var email: String
    @State private var code = ""
    @State var animate: Bool = false
    @FocusState private var isFocused: Bool
    @State var errorMsg: String = ""
    @FormState var formState

    private var placeHolder: String = "xxxxxx"
    let characterLimit = 6

    var disabled: Bool {
        code.isEmpty || code.count < 6 || formState.isLoading
    }

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
                .onChange(of: code) { _, _ in
                    errorMsg = ""
                }
                .onChange(of: isFocused) { _, newValue in
                    withAnimation(.smooth(duration: 0.15)) {
                        animate = newValue
                    }
                }
                .onChange(of: code) { _, newValue in
                    if newValue.count == characterLimit {
                        submitCode()
                    }
                    if newValue.count > characterLimit {
                        code = String(newValue.prefix(characterLimit))
                    }
                }
                .onSubmit {
                    submitCode()
                }
            Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
        }
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            VStack {
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
                .opacity(disabled ? 0.5 : 1)
                .padding(.horizontal, OnboardingUtils.shared.hPadding)
                .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
                .disabled(disabled)
            }
        }
        .onAppear {
            isFocused = true
        }
    }

    func submitCode() {
        Task {
            do {
                formState.startLoading()
                let result = try await api.verifyCode(code: code, email: email)
                if case let .success(result) = result {
                    Auth.shared.saveToken(result.token)
                    Auth.shared.saveCurrentUserId(userId: result.userId)

                    try await database.dbWriter.write { db in
                        let user = User(
                            id: result.userId,
                            email: email,
                            firstName: "",
                            lastName: nil
                        )
                        try user.save(db)
                    }

                    print("Token \(result.token)")

                    do {
                        try AppDatabase.authenticated()

                    } catch {
                        Log.shared.error("Failed to setup database or save user", error: error)
                    }

                    formState.reset()
                    nav.push(.addAccount(email: email))
                } else {
                    errorMsg = "Invalid code, please try again."
                }
            } catch let error as APIError {
                OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
            } catch {
                Log.shared.error("Unexpected error", error: error)
            }
        }
    }

    func decodeInt64(from string: String) -> Int64? {
        return Int64(string)
    }
}

#Preview {
    Code(email: "dena@noor.to")
}
