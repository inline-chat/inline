import SwiftUI

struct GrayButton<Label>: View
where Label: View {
  var action: () -> Void
  var label: Label

  init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
    self.action = action
    self.label = label()
  }

  @FocusState private var isFocused: Bool
  @State private var hovered: Bool = false

  var body: some View {
    if #available(macOS 14.0, *) {
      Button(action: action, label: { label })
        .buttonStyle(GrayButtonStyle(isFocused: isFocused, hovered: hovered))
        .focusEffectDisabled(true)
        .focused($isFocused)
        .onHover {
          hovered = $0
        }
    } else {
      Button(action: action, label: { label })
        .buttonStyle(GrayButtonStyle())
    }
  }

  struct GrayButtonStyle: ButtonStyle {
    var isFocused: Bool
    var hovered: Bool

    init(isFocused: Bool, hovered: Bool) {
      self.isFocused = isFocused
      self.hovered = hovered
    }

    init() {
      self.isFocused = false
      self.hovered = false
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
        .font(.system(size: 15, weight: .regular))
        .frame(height: 38)
        .padding(.horizontal)
        .background(background)
        .foregroundStyle(.primary.opacity(textOpacity))
        .cornerRadius(10)
        .overlay(content: {
          if isFocused {
            RoundedRectangle(cornerRadius: 10)
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
