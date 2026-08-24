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
  var prefix: LocalizedStringKey?
  var centersPlaceholder = false
  var size: Size = .large

  init(_ titleKey: LocalizedStringKey, text value: Binding<String>) {
    self.titleKey = titleKey
    self.value = value
    prompt = nil
    prefix = nil
  }

  init(
    _ titleKey: LocalizedStringKey, text value: Binding<String>, prompt: Text? = nil,
    size: Size = .large
  ) {
    self.titleKey = titleKey
    self.value = value
    self.prompt = prompt
    prefix = nil
    self.size = size
  }

  init(
    _ titleKey: LocalizedStringKey,
    text value: Binding<String>,
    prefix: LocalizedStringKey,
    centersPlaceholder: Bool = false,
    size: Size = .large
  ) {
    self.titleKey = titleKey
    self.value = value
    prompt = nil
    self.prefix = prefix
    self.centersPlaceholder = centersPlaceholder
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
      28
    case .medium:
      32
    case .large:
      36
    }
  }

  var cornerRadius: CGFloat {
    switch size {
    case .small:
      10
    case .medium:
      12
    case .large:
      12
    }
  }

  var body: some View {
    ZStack {
      HStack(spacing: 4) {
        if let prefix {
          Text(prefix)
            .foregroundStyle(.secondary)
        }

        TextField(
          titleKey,
          text: value,
          prompt: showsCenteredPlaceholder ? Text("") : prompt
        )
        .multilineTextAlignment(prefix == nil ? .center : .leading)
        .textFieldStyle(.plain)
        .focused($isFocused)
      }
      .padding(.horizontal, prefix == nil ? 0 : 12)

      if showsCenteredPlaceholder {
        Text(titleKey)
          .foregroundStyle(.tertiary)
          .allowsHitTesting(false)
      }
    }
    .font(font)
    .frame(height: height)
    .cornerRadius(cornerRadius)
    .background(
      RoundedRectangle(cornerRadius: cornerRadius)
        .foregroundStyle(.primary.opacity(isFocused ? 0.1 : 0.06))
        .animation(.snappy, value: isFocused)
        .frame(height: height)
    )
  }

  private var showsCenteredPlaceholder: Bool {
    centersPlaceholder && value.wrappedValue.isEmpty
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
