import InlineKit
import SwiftUI

struct PrivacySettingsDetailView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy
  @State private var fileLinkSenders: [LocalFileLinkTrust.Sender] = []

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

      if !fileLinkSenders.isEmpty {
        Section {
          ForEach(fileLinkSenders) { sender in
            LabeledContent(sender.name) {
              Button("Remove") {
                LocalFileLinkTrust.remove(id: sender.id)
                fileLinkSenders = LocalFileLinkTrust.senders
              }
            }
          }
        } header: {
          SettingsSectionHeader("Allowed to Open Local Files")
        }
      }
    }
    .settingsFormStyle()
    .onAppear { fileLinkSenders = LocalFileLinkTrust.senders }
  }
}

#Preview {
  PrivacySettingsDetailView()
}
