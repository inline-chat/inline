import InlineKit
import SwiftUI

struct AddAccount: View {
    var email: String
    @State var name = ""
    @State var animate: Bool = false
    @State var errorMsg: String = ""

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
                .onSubmit {
                    submitAccount()
                }
            Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
        }
        .onAppear {
            isFocused = true
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
            .opacity(name.isEmpty ? 0.5 : 1)
            .disabled(name.isEmpty)
        }
    }

    func submitAccount() {
        Task {
            do {
                guard !name.isEmpty else {
                    errorMsg = "Please enter your name"
                    return
                }
                let result = try await api.updateProfile(firstName: name, lastName: "", username: "")
                if case let .success(result) = result {
                    let user = User(from: result.user)
                    try await database.dbWriter.write { db in
                        try user.save(db)
                    }
                } else {
                    try await database.dbWriter.write { db in
                        var fetchedUser = try User.fetchOne(db, id: Auth.shared.getCurrentUserId()!)
                        fetchedUser?.firstName = name
                        try fetchedUser?.save(db)
                    }
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
