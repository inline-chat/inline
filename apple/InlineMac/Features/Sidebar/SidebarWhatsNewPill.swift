import SwiftUI

/// Invites the user to open the bundled What's New sheet; the close button dismisses it for good.
struct SidebarWhatsNewPill: View {
  let onOpen: () -> Void
  let onDismiss: () -> Void

  @Environment(\.appearsActive) private var appearsActive
  @State private var isHovering = false

  private static let cornerRadius: CGFloat = 13

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

    HStack(spacing: 0) {
      Button(action: onOpen) {
        HStack(spacing: 7) {
          Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.tint)
          Text("What’s New in Inline")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(isHovering ? .secondary : .tertiary)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss What’s New")
      .padding(.trailing, 2)
    }
    .background(background(shape: shape))
    .overlay(
      shape.stroke(Color.primary.opacity(appearsActive ? 0.12 : 0.07), lineWidth: 0.7)
    )
    .clipShape(shape)
    .onHover { isHovering = $0 }
  }

  @ViewBuilder
  private func background(shape: RoundedRectangle) -> some View {
    if #available(macOS 26.0, *) {
      shape
        .fill(.clear)
        .glassEffect(.regular.interactive(), in: shape)
    } else {
      shape
        .fill(.ultraThinMaterial)
    }
  }
}
