import HeadlineKit
import SwiftUI

struct Email: View {
    var prevEmail: String?
    @State private var email = ""
    @FocusState private var isFocused: Bool

    private var placeHolder: String = "dena@example.com"

    @EnvironmentObject var nav: Navigation

    init(prevEmail: String? = nil) {
        self.prevEmail = prevEmail
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Image(systemName: "at")
                .font(.largeTitle)
                .padding(.top, 50)
                .foregroundColor(.purple)
            Spacer()
            Text("Enter your email")
                .font(Font.custom("Red Hat Display", size: 28))
                .fontWeight(.medium)

            TextField(placeHolder, text: $email)
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
                nav.push(.code(email: email))
            } label: {
                Text("Continue")
            }
            .buttonStyle(SimpleButtonStyle())
            .padding(.bottom, 18)
            .padding(.horizontal, 44)
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
