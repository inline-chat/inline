import InlineKit
import SwiftUI

struct PrivacySettingsDetailView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $privacy.appearInGlobalSearch) {
          SettingsRowLabel(
            .appearInGlobalSearch,
            description: "Allow other people to find you by username in global search."
          )
        }
        .settingsSearchAnchor(.appearInGlobalSearch)
      } header: {
        SettingsSectionHeader("Discovery")
      }

      Section {
        Toggle(isOn: $privacy.shareTimeZone) {
          SettingsRowLabel(
            .shareTimeZone,
            description: "Allow people you chat with to see your local time."
          )
        }
        .settingsSearchAnchor(.shareTimeZone)
      } header: {
        SettingsSectionHeader("Time Zone")
      }
    }
    .settingsFormStyle()
  }
}

#Preview {
  PrivacySettingsDetailView()
}
