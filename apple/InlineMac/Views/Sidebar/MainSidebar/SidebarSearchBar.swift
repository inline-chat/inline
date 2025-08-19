import SwiftUI

struct SidebarSearchBar: View {
  var text: Binding<String>
  var isFocused: Bool

  var body: some View {
    OutlineField(
      "Search (⌘K)",
      text: text,
      prompt: Text("Search").foregroundColor(.secondary),
      size: .regular,
      isFocused: isFocused
    )
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
  var isFocused: Bool

  init(_ titleKey: LocalizedStringKey, text value: Binding<String>, isFocused: Bool) {
    self.titleKey = titleKey
    self.value = value
    prompt = nil
    self.isFocused = isFocused
  }

  init(
    _ titleKey: LocalizedStringKey, text value: Binding<String>, prompt: Text? = nil,
    size: Size = .regular, isFocused: Bool
  ) {
    self.titleKey = titleKey
    self.value = value
    self.prompt = prompt
    self.size = size
    self.isFocused = isFocused
  }

  // @FocusState private var isFocused: Bool

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
      // .focused($isFocused)
      .cornerRadius(cornerRadius)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(isFocused ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02))
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
