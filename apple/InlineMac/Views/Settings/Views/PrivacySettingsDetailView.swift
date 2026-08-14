import InlineKit
import SwiftUI

struct PrivacySettingsDetailView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $privacy.appearInGlobalSearch) {
          SettingsRowLabel(
            "Appear in Global Search",
            description: "Allow other people to find you by username in global search."
          )
        }
      } header: {
        SettingsSectionHeader("Discovery")
      }

      Section {
        Toggle(isOn: $privacy.shareTimeZone) {
          SettingsRowLabel(
            "Share Time Zone",
            description: "Allow people you chat with to see your local time."
          )
        }
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
