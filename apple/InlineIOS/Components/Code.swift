import HeadlineKit
import SwiftUI

struct Code: View {
    var email: String
    @State private var code = ""
    @State var animate: Bool = false
    @FocusState private var isFocused: Bool

    private var placeHolder: String = "xxx xxx"

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
    }

    func submitCode() {
        Task {
            do {
                let result = try await api.verifyCode(code: code, email: email)

                userData.setId(Int64(result.userId) ?? 0)
                Auth.shared.saveToken(result.token)
                nav.push(.addAccount(email: email))
                do {
                    try database.setupDatabase()
                    print("Database setup successful")
                } catch {
                    Log.shared.error("Failed to setup database", error: error)
                }

            } catch {
                Log.shared.error("Failed to verify code", error: error)
            }
        }
    }
}

#Preview {
    Code(email: "dena@noor.to")
}
