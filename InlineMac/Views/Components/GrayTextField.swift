import SwiftUI

struct GrayTextField: View {
  enum Size {
    case small
    case medium
    case large
  }

  var titleKey: LocalizedStringKey
  var value: Binding<String>
  var prompt: Text?
  var size: Size = .large

  init(_ titleKey: LocalizedStringKey, text value: Binding<String>) {
    self.titleKey = titleKey
    self.value = value
    self.prompt = nil
  }

  init(
    _ titleKey: LocalizedStringKey, text value: Binding<String>, prompt: Text? = nil,
    size: Size = .large
  ) {
    self.titleKey = titleKey
    self.value = value
    self.prompt = prompt
    self.size = size
  }

  @FocusState private var isFocused: Bool

  var font: Font {
    switch size {
    case .small:
      return Font.system(size: 14, weight: .regular)
    case .medium:
      return Font.system(size: 16, weight: .regular)
    case .large:
      return Font.system(size: 17, weight: .regular)
    }
  }

  var height: CGFloat {
    switch size {
    case .small:
      return 28
    case .medium:
      return 32
    case .large:
      return 36
    }
  }

  var cornerRadius: CGFloat {
    switch size {
    case .small:
      return 6
    case .medium:
      return 8
    case .large:
      return 10
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
          .foregroundStyle(.primary.opacity(isFocused ? 0.1 : 0.06))
          .animation(.snappy, value: isFocused)
          .frame(height: height)
      )
  }
}

@available(macOS 14, *)
#Preview("Gray Text Field") {
  @Previewable @State var text = ""

  GrayTextField("Your Email", text: $text)
    .padding()
}

@available(macOS 14, *)
#Preview("Gray Text Field (Medium)") {
  @Previewable @State var text = ""

  GrayTextField("Your Email", text: $text, size: .medium)
    .padding()
}

@available(macOS 14, *)
#Preview("Gray Text Field (Small)") {
  @Previewable @State var text = ""

  GrayTextField("Your Email", text: $text, size: .small)
    .padding()
}
