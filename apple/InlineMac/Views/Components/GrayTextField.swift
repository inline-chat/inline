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
    prompt = nil
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
        Font.body
      case .medium:
        Font.system(size: 16, weight: .regular)
      case .large:
        Font.system(size: 17, weight: .regular)
    }
  }

  var height: CGFloat {
    switch size {
      case .small:
        26
      case .medium:
        32
      case .large:
        36
    }
  }

  var cornerRadius: CGFloat {
    switch size {
      case .small:
        6
      case .medium:
        8
      case .large:
        10
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
