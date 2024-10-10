import HeadlineKit
import SwiftUI

struct Email: View {
    var prevEmail: String?
    @State private var email = ""
    @FocusState private var isFocused: Bool
    @State private var animate: Bool = false

    private var placeHolder: String = "dena@example.com"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient

    init(prevEmail: String? = nil) {
        self.prevEmail = prevEmail
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
                    } catch {
                        Log.shared.error("Failed to send code", error: error)
                    }
                }
            }
            .buttonStyle(SimpleButtonStyle())
            .padding(.horizontal, OnboardingUtils.shared.hPadding)
            .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
        }
        .onAppear {
            if let prevEmail = prevEmail {
                email = prevEmail
            }
        }
    }
}

#Preview {
    Email()
}
