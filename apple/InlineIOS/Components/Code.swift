import InlineKit
import SwiftUI

struct Code: View {
    var email: String
    @State private var code = ""
    @State var animate: Bool = false
    @FocusState private var isFocused: Bool
    @State var errorMsg: String = ""

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

                Button {
                    submitCode()

                } label: {
                    Text("Continue")
                }
                .buttonStyle(SimpleButtonStyle())
                .padding(.horizontal, OnboardingUtils.shared.hPadding)
                .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
            }
        }
        .onAppear {
            isFocused = true
        }
    }

    func submitCode() {
        Task {
            do {
                let result = try await api.verifyCode(code: code, email: email)

                let userId = Int64(result.userId) ?? 0
                print("Received userId: \(userId)")
                userData.setId(userId)
                Auth.shared.saveToken(result.token)

                print("TOKEN \(result.token)")
                do {
                    try database.setupDatabase()
                    print("Database setup successful")

                } catch {
                    Log.shared.error("Failed to setup database or save user", error: error)
                    print("Detailed error: \(error)")
                }

                nav.push(.addAccount(email: email))

            } catch let error as APIError {
                OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
            } catch {
                Log.shared.error("Unexpected error", error: error)
                print("Detailed unexpected error: \(error)")
            }
        }
    }
}

#Preview {
    Code(email: "dena@noor.to")
}
