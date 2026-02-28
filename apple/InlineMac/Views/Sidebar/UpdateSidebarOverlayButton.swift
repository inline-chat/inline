import SwiftUI

struct UpdateSidebarOverlayButton: View {
  @EnvironmentObject private var updateInstallState: UpdateInstallState

  var body: some View {
    if updateInstallState.isReadyToInstall {
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

#Preview {
  UpdateSidebarOverlayButton()
    .environmentObject(UpdateInstallState())
    .padding()
}
