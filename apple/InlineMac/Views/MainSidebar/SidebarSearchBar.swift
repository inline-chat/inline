import SwiftUI

struct SidebarSearchBar: View {
  var text: Binding<String>

  var body: some View {
    OutlineField("Search", text: text, prompt: Text("Search").foregroundColor(.secondary), size: .regular)
      .submitLabel(.search)
      .autocorrectionDisabled()
  }
}

struct OutlineField: View {
  enum Size {
    case regular
  }

  var titleKey: LocalizedStringKey
  var value: Binding<String>
  var prompt: Text?
  var size: Size = .regular

  init(_ titleKey: LocalizedStringKey, text value: Binding<String>) {
    self.titleKey = titleKey
    self.value = value
    prompt = nil
  }

  init(
    _ titleKey: LocalizedStringKey, text value: Binding<String>, prompt: Text? = nil,
    size: Size = .regular
  ) {
    self.titleKey = titleKey
    self.value = value
    self.prompt = prompt
    self.size = size
  }

  @FocusState private var isFocused: Bool

  var font: Font {
    switch size {
      case .regular:
        Font.body
    }
  }

  var height: CGFloat {
    switch size {
      case .regular:
        28
    }
  }

  var cornerRadius: CGFloat {
    switch size {
      case .regular:
        8
    }
  }

  var body: some View {
    TextField(titleKey, text: value, prompt: prompt)
      .multilineTextAlignment(.center)
      .textFieldStyle(.plain)
      .font(font)
      .frame(height: height)
      .focused($isFocused)
      .cornerRadius(cornerRadius)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(.primary.opacity(0.05))
          .animation(.easeOut.speed(3), value: isFocused)
      )
//      .overlay(
//        RoundedRectangle(cornerRadius: cornerRadius)
//          .strokeBorder(
//            Color.primary.opacity(isFocused ? 0.12 : 0.1),
//            lineWidth: 1
//          )
//          .animation(.easeOut.speed(2), value: isFocused)
//      )
  }
}
