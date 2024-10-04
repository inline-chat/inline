import HeadlineKit
import SwiftUI

struct AddAccount: View {
    var email: String
    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var placeHolder: String = "Dena"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient
    @Environment(\.appDatabase) var database

    init(email: String) {
        self.email = email
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Image(systemName: "person.fill")
                .font(.largeTitle)
                .padding(.top, 50)
                .foregroundColor(.cyan)
            Spacer()
            Text("Enter your name")
                .font(Font.custom("Red Hat Display", size: 28))
                .fontWeight(.medium)

            TextField(placeHolder, text: $name)
                .textFieldStyle(OutlinedTextFieldStyle(isFocused: isFocused))
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .frame(minWidth: 220)
                .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button {
                submitAccount()
            } label: {
                Text("Continue")
            }
            .buttonStyle(SimpleButtonStyle())
            .padding(.bottom, 18)
            .padding(.horizontal, 44)
        }
    }

    func submitAccount() {
        Task {
            do {
                try await database.dbWriter.write { db in
                    let user = User(
                        email: email,
                        firstName: name
                    )
                    try user.insert(db)
                }
            } catch {
                Log.shared.error("Failed to create user", error: error)
            }
        }
    }
}

#Preview {
    AddAccount(email: "")
}
