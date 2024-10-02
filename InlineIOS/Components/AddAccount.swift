import HeadlineKit
import SwiftUI

struct AddAccount: View {
    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var placeHolder: String = "Dena"

    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var api: ApiClient

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
    AddAccount()
}
