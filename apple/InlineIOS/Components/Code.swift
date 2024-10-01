import HeadlineKit
import SwiftUI

struct Code: View {
    var email: String
    @State private var code = ""
    @FocusState private var isFocused: Bool

    private var placeHolder: String = "xxx xxx"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient

    init(email: String) {
        self.email = email
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Image(systemName: "person.badge.key")
                .font(.largeTitle)
                .padding(.top, 50)
                .foregroundColor(.pink)
            Spacer()
            Text("Enter the code")
                .font(Font.custom("Red Hat Display", size: 28))
                .fontWeight(.medium)

            TextField(placeHolder, text: $code)
                .textFieldStyle(OutlinedTextFieldStyle(isFocused: isFocused))
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .frame(maxWidth: 220)
            HStack(spacing: 2) {
                Text("Code sent to \(email).")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button("Edit") {
                    nav.push(.email(prevEmail: email))
                }
                .font(.callout)
            }
            Spacer()
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    do {
                        try await api.verifyCode(code: code, email: email)
                    } catch {
                        print("ERORORORO \(error)")
                    }
                }
            } label: {
                Text("Continue")
            }
            .buttonStyle(SimpleButtonStyle())
            .padding(.bottom, 18)
            .padding(.horizontal, 44)
        }
    }
}

#Preview {
    Code(email: "dena@noor.to")
}
