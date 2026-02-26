import SwiftUI

struct UpdateSidebarOverlayButton: View {
  enum Placement {
    case bottomOverlay
    case topCorner
  }

  @EnvironmentObject private var updateInstallState: UpdateInstallState
  var placement: Placement = .bottomOverlay

  var body: some View {
    if updateInstallState.isReadyToInstall {
      if case .topCorner = placement {
        Button(action: {
          updateInstallState.install()
        }) {
          Text("Update")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
          Capsule()
            .fill(Color.accent)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
        .accessibilityLabel("Update")
      } else {
        InlineButton(size: .large, style: .primary, action: {
          updateInstallState.install()
        }) {
          Text("Update")
        }
        .frame(minWidth: 160)
        .shadow(color: Color.black.opacity(0.15), radius: 8, y: 3)
        .accessibilityLabel("Update")
      }
    }
  }
}

#Preview {
  UpdateSidebarOverlayButton()
    .environmentObject(UpdateInstallState())
    .padding()
}
