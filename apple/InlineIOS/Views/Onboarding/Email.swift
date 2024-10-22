import InlineKit
import SwiftUI

enum LoginMethod {
    case email
    case phone
}

struct Email: View {
    var prevEmail: String?
    @State private var email = ""
    @State private var num = ""
    @FocusState private var isFocused: Bool
    @State private var animate: Bool = false
    @State var errorMsg: String = ""
    @State var loginMethod: LoginMethod = .email

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
            if loginMethod == .email {
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
            } else {
                AnimatedLabel(animate: $animate, text: "Enter your phone")
                TextField("eg. +1234567890", text: $num)
                    .focused($isFocused)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.vertical, 8)
                    .onChange(of: num) { _, _ in
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
            }
            Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
        }
        .padding(.horizontal, 50)
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button(formState.isLoading ? "Sending Code..." : "Continue") {
                    submit()
                }
                .buttonStyle(SimpleButtonStyle())
                .padding(.horizontal, OnboardingUtils.shared.hPadding)
                .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
                .disabled(loginMethod == .phone ? num.isEmpty : disabled)
                .opacity(loginMethod == .phone ? num.isEmpty ? 0.5 : 1 : disabled ? 0.5 : 1)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Login Method", selection: $loginMethod) {
                Text("Email").tag(LoginMethod.email)
                Text("Phone").tag(LoginMethod.phone)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, OnboardingUtils.shared.hPadding)
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
                if loginMethod == .email {
                    let _ = try await api.sendCode(email: email)
                } else {
                    let _ = try await api.sendCode(phone: num)
                }
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
