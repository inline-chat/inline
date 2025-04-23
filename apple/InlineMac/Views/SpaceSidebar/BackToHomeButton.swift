import SwiftUI

struct BackToHomeButton: View {
  @EnvironmentObject var nav: Nav

  @State var isHovered = false

  var body: some View {
    Button {
      nav.openHome()
    } label: {
      Image(systemName: "chevron.compact.left")
        .font(.body.bold())
        .foregroundStyle(.tertiary)
    }
    .help("Go back to home")
    .buttonStyle(BackButtonStyle())
  }

  struct BackButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
      let isPressed = configuration.isPressed
      let fill = isHovered ? Color.gray.opacity(0.1) : isPressed ? Color.gray.opacity(0.15) : Color.clear

      configuration.label
        .padding(6)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(fill)
        )
        .contentShape(.rect)
        .cornerRadius(8)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .onHover { hovering in
          isHovered = hovering
        }
    }
  }
}
