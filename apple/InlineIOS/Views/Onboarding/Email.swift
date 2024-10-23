import InlineKit
import SwiftUI

struct Email: View {
    var prevEmail: String?
    @State private var email = ""
    @FocusState private var isFocused: Bool
    @State private var animate: Bool = false
    @State var errorMsg: String = ""
    @FormState var formState

    private var placeHolder: String = "dena@example.com"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient

    init(prevEmail: String? = nil) {
        self.prevEmail = prevEmail
    }

    var disabled: Bool {
        email.isEmpty || !email.contains("@") || !email.contains(".") || formState.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AnimatedLabel(animate: $animate, text: "Enter your email")
            TextField(placeHolder, text: $email)
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.vertical, 8)
                .onChange(of: email) { _, _ in
                    errorMsg = ""
                }
                .onChange(of: isFocused) { _, newValue in
                    withAnimation(.smooth(duration: 0.15)) {
                        animate = newValue
                    }
                }
                .onSubmit {
                    if !disabled {
                        submit()
                    }
                }
            Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
        }
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button(formState.isLoading ? "Sending Code..." : "Continue") {
                    submit()
                }
                .buttonStyle(SimpleButtonStyle())
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OnboardingUtils.shared.hPadding)
                .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
            }
        }
        .onAppear {
            if let prevEmail = prevEmail {
                email = prevEmail
            }
            isFocused = true
        }
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
            }
        }
    }
}

#Preview {
    Email()
}
