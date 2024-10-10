import HeadlineKit
import SwiftUI

struct AddAccount: View {
    var email: String
    @State private var name = ""
    @State var animate: Bool = false

    @FocusState private var isFocused: Bool

    private var placeHolder: String = "Dena"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient
    @EnvironmentObject var userData: UserData
    @Environment(\.appDatabase) var database

    init(email: String) {
        self.email = email
    }

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
        }
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button {
                submitAccount()

            } label: {
                Text("Continue")
            }
            .buttonStyle(SimpleButtonStyle())
            .padding(.horizontal, OnboardingUtils.shared.hPadding)
            .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
        }
    }

    func submitAccount() {
        Task {
            do {
                try await database.dbWriter.write { db in
                    let user = User(
                        id: userData.getId() ?? Int64.random(in: 1 ... 6000),
                        email: email,
                        firstName: name
                    )
                    try user.save(db)
                }
                nav.push(.main)
            } catch {
                Log.shared.error("Failed to create user", error: error)
            }
        }
    }
}

#Preview {
    AddAccount(email: "")
}
