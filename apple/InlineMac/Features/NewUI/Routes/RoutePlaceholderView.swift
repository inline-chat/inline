import SwiftUI

struct RoutePlaceholderView: View {
  let title: String
  let systemImage: String

  @State private var symbolEffectToken = 0

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: systemImage)
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(.tertiary)
        .routePlaceholderSymbolEffect(value: symbolEffectToken)

      Text(title)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.tertiary)
    }
    .padding(18)
    .onHover { hovering in
      if hovering {
        symbolEffectToken += 1
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private extension View {
  @ViewBuilder
  func routePlaceholderSymbolEffect(value: Int) -> some View {
    if #available(macOS 14.0, *) {
      symbolEffect(.bounce, value: value)
    } else {
      self
    }
  }
}
