import SwiftUI

struct OutlinedTextFieldStyle: TextFieldStyle {
  let isFocused: Bool

  func _body(configuration: TextField<_Label>) -> some View {
    VStack(spacing: 0) {
      configuration
        .font(.title2.weight(.medium))
        .padding(.vertical, 12)
        .multilineTextAlignment(.center)

      Rectangle()
        .fill(isFocused ? Color(.systemGray4) : Color.clear)
        .frame(height: 2)
        .animation(.default, value: isFocused)
    }
    .frame(maxWidth: .infinity)
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
