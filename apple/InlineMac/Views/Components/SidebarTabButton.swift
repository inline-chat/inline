import SwiftUI

struct SidebarTabButton: View {
  let systemImage: String
  let isActive: Bool
  let action: () -> Void
  let accessibilityLabel: LocalizedStringKey?
  let fontSize: CGFloat

  init(
    systemImage: String,
    isActive: Bool,
    fontSize: CGFloat = 16,
    accessibilityLabel: LocalizedStringKey? = nil,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.isActive = isActive
    self.fontSize = fontSize
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  var accessibilityLabelText: Text {
    if let label = accessibilityLabel {
      Text(label)
    } else {
      Text(systemImage)
    }
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(isActive ? Color.accent : Color.gray.opacity(0.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityLabel(
          accessibilityLabelText
        )
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
