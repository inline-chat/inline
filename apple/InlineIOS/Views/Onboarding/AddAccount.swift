import InlineKit
import SwiftUI

enum UsernameStatus {
    case checking
    case available
    case taken
}

struct AddAccount: View {
    @State var name = ""
    @State var username = ""
    @State var animate: Bool = false
    @State var errorMsg: String = ""
    @State var isInputValid: Bool = false

    @FocusState private var isFocused: Bool
    @FocusState private var isUsernameFocused: Bool

    private var placeHolder: String = "Dena"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient
    @EnvironmentObject var userData: UserData
    @Environment(\.appDatabase) var database

    @State var usernameStatus: UsernameStatus = .checking

    @FormState var formState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AnimatedLabel(animate: $animate, text: "Enter the name")
            TextField(placeHolder, text: $name)
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.vertical, 8)
                .onChange(of: isFocused) { _, newValue in
                    withAnimation(.smooth(duration: 0.15)) {
                        animate = newValue
                    }
                }
            TextField("Username", text: $username)
                .focused($isUsernameFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.vertical, 8)
                .onChange(of: username) { _, newValue in
                    errorMsg = ""
                    let trimmedUsername = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedUsername.isEmpty && trimmedUsername.count >= 2 {
                        withAnimation(.smooth(duration: 0.15)) {
                            usernameStatus = .checking
                        }
                        Task {
                            do {
                                try? await Task.sleep(for: .seconds(1.8))
                                let result = try await api.checkUsername(username: trimmedUsername)

                                withAnimation(.smooth(duration: 0.15)) {
                                    usernameStatus = result.available ? .available : .taken
                                }

                            } catch {
                                Log.shared.error("Failed to check username", error: error)
                            }
                        }
                    } else {
                        usernameStatus = .checking
                    }
                }
                .overlay(alignment: .trailing) {
                    if username.count >= 2 {
                        switch usernameStatus {
                        case .checking:
                            Image(systemName: "hourglass")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        case .available:
                            Image(systemName: "checkmark.circle")
                                .font(.callout)
                                .foregroundColor(.green)
                        case .taken:
                            Image(systemName: "xmark.circle")
                                .font(.callout)
                                .foregroundColor(.red)
                        }
                    }
                }
        }
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading) {
                Text(errorMsg)
                    .font(.callout)
                    .foregroundColor(.red)
                    .padding(.bottom, 8)

                Button(formState.isLoading ? "Creating Account..." : "Continue") {
                    submitAccount()
                }
                .buttonStyle(SimpleButtonStyle())
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OnboardingUtils.shared.hPadding)
                .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
                .disabled(!isInputValid || formState.isLoading)
                .opacity((!isInputValid || formState.isLoading) ? 0.5 : 1)
            }
        }
        .onChange(of: name) { _, _ in
            validateInput()
        }
        .onChange(of: username) { _, _ in
            validateInput()
        }
    }

    private func validateInput() {
        errorMsg = ""
        isInputValid = !name.isEmpty && !username.isEmpty && usernameStatus == .available
    }

    func submitAccount() {
        Task {
            do {
                formState.startLoading()
                guard !name.isEmpty else {
                    errorMsg = "Please enter your name"
                    formState.reset()
                    return
                }
                let result = try await api.updateProfile(firstName: name, lastName: "", username: username)

                let user = User(from: result.user)
                try await database.dbWriter.write { db in
                    try user.save(db)
                }

                formState.reset()
                nav.push(.main)
            } catch {
                Log.shared.error("Failed to create user", error: error)
                errorMsg = "Failed to create account. Please try again."
                formState.reset()
                isInputValid = false
            }
        }
    }
}

#Preview {
    AddAccount()
}
