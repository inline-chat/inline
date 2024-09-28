import SwiftUI

struct Email: View {
    @State private var email = ""
    @FocusState private var isFocused: Bool

    private var placeHolder: String = "dena@example.com"

    var body: some View {
        VStack {
            Text("Enter your email")
                .font(Font.custom("Red Hat Display", size: 22))
                .fontWeight(.medium)
                .padding(.bottom, 6)
            TextField(placeHolder, text: $email)
                .textFieldStyle(OutlinedTextFieldStyle(isFocused: isFocused))
                .focused($isFocused)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Button {
            } label: {
                Text("Continue")
            }
            .buttonStyle(GlassyButtonStyle())
        }
    }
}

#Preview {
    Email()
}

#Preview {
    Email()
        .environment(\.locale, .init(identifier: "zh-CN"))
}

#Preview {
    Email()
        .environment(\.locale, .init(identifier: "zh-TW"))
}
