import InlineKit
import SwiftUI

struct AddAccount: View {
    var email: String
    @State private var name = ""
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
                guard !name.isEmpty else {
                    errorMsg = "Please enter your name"
                    return
                }
                try await database.dbWriter.write { db in
                    if let id = userData.getId() {
                        var existingUser = try User.fetchOne(db, id: id)
                        existingUser?.firstName = name
                        existingUser?.email = email
                        try existingUser?.save(db)
                    } else {
                        let user = User(id: Int64.random(in: 10 ... 999), email: email, firstName: name, lastName: nil)
                        try user.insert(db)
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
