import SwiftUI

struct InlineButton<Label>: View
  where Label: View
{
  enum InlineButtonStyle {
    case secondary
    case primary
  }

  var action: () -> Void
  var label: Label
  var size: ButtonSize
  var style: InlineButtonStyle = .secondary

  enum ButtonSize {
    case small
    case medium
    case large
  }

  init(
    size: ButtonSize? = nil,
    style: InlineButtonStyle = .secondary,
    action: @escaping @MainActor () -> Void,
    @ViewBuilder label: () -> Label
  ) {
    self.action = action
    self.label = label()
    self.size = size ?? .large
    self.style = style
  }

  @FocusState private var isFocused: Bool
  @State private var hovered: Bool = false

  var body: some View {
    if #available(macOS 14.0, *) {
      Button(action: action, label: { label })
        .buttonStyle(GrayButtonStyle(size: size, style: style, isFocused: isFocused, hovered: hovered))
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
    var style: InlineButtonStyle

    init(
      size: ButtonSize,
      style: InlineButtonStyle = .secondary,
      isFocused: Bool? = nil,
      hovered: Bool? = nil
    ) {
      self.isFocused = isFocused ?? false
      self.hovered = hovered ?? false
      self.size = size
      self.style = style
    }

    var font: Font {
      switch size {
        case .small:
          Font.system(size: 13, weight: .regular)
        case .medium:
          Font.system(size: 15, weight: .regular)
        case .large:
          Font.system(size: 16, weight: .regular)
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

    var pressedBackground: Color {
      switch style {
        case .secondary:
          Color.primary.opacity(0.15)
        case .primary:
          if #available(macOS 15.0, *) {
            Color.accentColor.mix(with: .black, by: 0.05)
          } else {
            // Fallback on earlier versions
            Color.accentColor.opacity(0.9)
          }
      }
    }

    var hoveredBackground: Color {
      switch style {
        case .secondary:
          Color.primary.opacity(0.13)
        case .primary:
          if #available(macOS 15.0, *) {
            Color.accentColor.mix(with: .white, by: 0.2)
          } else {
            // Fallback on earlier versions
            Color.accentColor.opacity(0.95)
          }
      }
    }

    var background: Color {
      switch style {
        case .secondary:
          Color.primary.opacity(0.09)
        case .primary:
          Color.accentColor
      }
    }

    var foreground: Color {
      switch style {
        case .secondary:
          Color.primary
        case .primary:
          Color.white
      }
    }
    
    func makeBody(configuration: Configuration) -> some View {
      let background: Color =
        configuration.isPressed
          ? pressedBackground : hovered ? hoveredBackground : background
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
        .foregroundStyle(foreground.opacity(textOpacity))
        .cornerRadius(cornerRadius)
        .overlay(content: {
          if isFocused {
            RoundedRectangle(cornerRadius: cornerRadius)
              .stroke(lineWidth: 2.0)
              .foregroundStyle(hoveredBackground)
          }
        })
        .scaleEffect(x: scale, y: scale)
        .animation(.mediumFeedback, value: animation)
    }
  }
}

#Preview("Gray Button (Light)") {
  VStack {
    InlineButton(action: {}, label: { Text("Continue") })
      .padding()

    InlineButton(style: .primary, action: {}, label: { Text("Continue") })
      .padding()
  }.padding()
    .preferredColorScheme(.light)
}

#Preview("Gray Button (Dark)") {
  VStack {
    InlineButton(action: {}, label: { Text("Continue") })
      .padding()
    
    InlineButton(style: .primary, action: {}, label: { Text("Continue") })
      .padding()
  }.padding()
    .preferredColorScheme(.dark)
}
