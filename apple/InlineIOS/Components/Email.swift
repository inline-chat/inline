import InlineKit
import SwiftUI

struct Email: View {
    var prevEmail: String?
    @State private var email = ""
    @FocusState private var isFocused: Bool
    @State private var animate: Bool = false
    @State var errorMsg: String = ""
    private var placeHolder: String = "dena@example.com"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient

    init(prevEmail: String? = nil) {
        self.prevEmail = prevEmail
    }

    var disabled: Bool {
        email.isEmpty || !email.contains("@") || !email.contains(".")
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
                .onChange(of: isFocused) { _, newValue in
                    withAnimation(.smooth(duration: 0.15)) {
                        animate = newValue
                    }
                }
        }
        .padding(.horizontal, 50)
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button("Continue") {
                Task {
                    do {
                        try await api.sendCode(email: email)
                        nav.push(.code(email: email))
                    } catch let error as APIError {
                        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
                    }
                }
            }
            .buttonStyle(SimpleButtonStyle())
            .padding(.horizontal, OnboardingUtils.shared.hPadding)
            .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
        }
        .onAppear {
            if let prevEmail = prevEmail {
                email = prevEmail
            }
            isFocused = true
        }
    }
}

#Preview {
    Email()
}