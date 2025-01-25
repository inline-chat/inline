import SwiftUI

struct GrayButton<Label>: View
  where Label: View
{
  var action: () -> Void
  var label: Label
  var size: ButtonSize

  enum ButtonSize {
    case small
    case medium
    case large
  }

  init(size: ButtonSize? = nil, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
    self.action = action
    self.label = label()
    self.size = size ?? .large
  }

  @FocusState private var isFocused: Bool
  @State private var hovered: Bool = false

  var body: some View {
    if #available(macOS 14.0, *) {
      Button(action: action, label: { label })
        .buttonStyle(GrayButtonStyle(size: size, isFocused: isFocused, hovered: hovered))
        .focusEffectDisabled(true)
        .focused($isFocused)
        .onHover {
          hovered = $0
        }
    } else {
      Button(action: action, label: { label })
        .buttonStyle(GrayButtonStyle(size: size))
    }
  }

  struct GrayButtonStyle: ButtonStyle {
    var isFocused: Bool
    var hovered: Bool
    var size: ButtonSize

    init(size: ButtonSize, isFocused: Bool? = nil, hovered: Bool? = nil) {
      self.isFocused = isFocused ?? false
      self.hovered = hovered ?? false
      self.size = size
    }

    var font: Font {
      switch size {
        case .small:
          Font.system(size: 13, weight: .regular)
        case .medium:
          Font.system(size: 15, weight: .regular)
        case .large:
          Font.system(size: 17, weight: .regular)
      }
    }

    var height: CGFloat {
      switch size {
        case .small:
          24
        case .medium:
          28
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

    func makeBody(configuration: Configuration) -> some View {
      let background: Color =
        configuration.isPressed
          ? .primary.opacity(0.15) : hovered ? .primary.opacity(0.13) : .primary.opacity(0.09)
      //            let background: Color = .accentColor
      let scale: CGFloat = configuration.isPressed ? 0.95 : 1
      let textOpacity: Double = configuration.isPressed ? 0.8 : 0.95
      let animation =
        (isFocused ? 100 : 0) + (configuration.isPressed ? 10 : 0) + (hovered ? 1 : 0)

      return configuration.label
        .font(font)
        .frame(height: height)
        .padding(.horizontal)
        .background(background)
        .foregroundStyle(.primary.opacity(textOpacity))
        .cornerRadius(cornerRadius)
        .overlay(content: {
          if isFocused {
            RoundedRectangle(cornerRadius: cornerRadius)
              .stroke(lineWidth: 1.0)
              .foregroundStyle(.primary.opacity(0.3))
          }
        })
        .scaleEffect(x: scale, y: scale)
        .animation(.snappy.speed(2.0), value: animation)
    }
  }
}

#Preview("Gray Button (Light)") {
  GrayButton(action: {}, label: { Text("Continue") })
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Gray Button (Dark)") {
  GrayButton(action: {}, label: { Text("Continue") })
    .padding()
    .preferredColorScheme(.dark)
}
