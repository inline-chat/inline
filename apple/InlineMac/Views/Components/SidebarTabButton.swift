import SwiftUI

struct SidebarTabButton: View {
  let label: LocalizedStringKey?
  let systemImage: String
  let isActive: Bool
  let action: () -> Void
  let accessibilityLabel: LocalizedStringKey?
  let fontSize: CGFloat

  init(
    label: LocalizedStringKey? = nil,
    systemImage: String,
    isActive: Bool,
    fontSize: CGFloat = 16,
    accessibilityLabel: LocalizedStringKey? = nil,
    action: @escaping () -> Void
  ) {
    self.label = label
    self.systemImage = systemImage
    self.isActive = isActive
    self.fontSize = fontSize
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var accessibilityLabelText: Text {
    if let label {
      Text(label)
    } else {
      Text(systemImage)
    }
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 0) {
        Image(systemName: systemImage)
          .font(.system(size: fontSize, weight: .bold))
          .foregroundStyle(isActive ? Color.accent : Color.gray.opacity(0.5))
          .frame(width: 26, height: 26)
          .accessibilityLabel(
            accessibilityLabelText
          )

        if let label {
          Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(isActive ? Color.accent : Color.gray.opacity(0.8))
        }
      }
      .padding(.horizontal, 14)
      .contentShape(.rect)
    }
    .help(accessibilityLabel ?? "")
    .buttonStyle(.plain)
  }
}

#Preview {
  HStack {
    SidebarTabButton(systemImage: "archivebox.fill", isActive: true, action: {})
    SidebarTabButton(systemImage: "bubble.left.and.bubble.right.fill", isActive: false, action: {})
    SidebarTabButton(systemImage: "person.2.fill", isActive: false, action: {})
  }
  .background(Color(.windowBackgroundColor))
  .frame(height: 42)
  .padding()
}
