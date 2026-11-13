import InlineGrid
import SwiftUI

/// Grid's sound preference for General settings. Shown only to people who
/// have Grid in one of their spaces, like the Grid entry on Home.
struct GridSettingsSection: View {
  private let store = GridIOSRuntime.shared.rooms

  var body: some View {
    @Bindable var store = store

    if GridHomeEntryProjection(store: store, spaceID: nil).isEligible {
      Section {
        SettingsItem(icon: "mic.fill", iconColor: .green, title: String(localized: "Microphone Sounds")) {
          Toggle("Microphone Sounds", isOn: $store.playsMicrophoneSounds)
            .labelsHidden()
        }
      } header: {
        Text("Grid")
      } footer: {
        Text("Play a short sound when you mute or unmute your microphone.")
      }
    }
  }
}
