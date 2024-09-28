import SwiftUI

struct OutlinedTextFieldStyle: TextFieldStyle {
    let isFocused: Bool

    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .font(.body.weight(.medium))
            .padding(.vertical, 12)
            .multilineTextAlignment(.center)
            .frame(width: 250)
            .padding(.horizontal)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color(.systemGray5), lineWidth: 2)
            )
            .animation(.default, value: isFocused)
    }
}

struct ExampleView: View {
    @State private var email = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Email", text: $email)
            .textFieldStyle(OutlinedTextFieldStyle(isFocused: isFocused))
            .focused($isFocused)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding()
    }
}

struct ExampleView_Previews: PreviewProvider {
    static var previews: some View {
        ExampleView()
    }
}
