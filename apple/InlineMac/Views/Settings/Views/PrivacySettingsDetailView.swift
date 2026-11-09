import InlineKit
import InlineUI
import SwiftUI

struct PrivacySettingsDetailView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy
  @State private var fileLinkSenders: [LocalFileLinkTrust.Sender] = []
  @State private var isEditingTimeZoneExceptions = false

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
        Picker(selection: timeZoneAudience) {
          Text("Everyone").tag(PrivacyRuleValue.Audience.everyone)
          Text("Nobody").tag(PrivacyRuleValue.Audience.nobody)
        } label: {
          SettingsRowLabel(
            .shareTimeZone,
            description: "Who can see your local time in chats and on your profile."
          )
        }
        .settingsSearchAnchor(.shareTimeZone)

        LabeledContent(timeZoneRule.exceptionsTitle) {
          Button(exceptionsButtonTitle) {
            isEditingTimeZoneExceptions = true
          }
        }
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
    .sheet(isPresented: $isEditingTimeZoneExceptions) {
      PrivacyPeopleEditor(
        title: timeZoneRule.exceptionsTitle,
        footer: timeZoneRule.audience == .everyone
          ? "These people won’t see your local time."
          : "Only these people will see your local time.",
        selectedIDs: timeZoneRule.exceptions
      ) { ids in
        var rule = privacy.effectiveTimeZoneRule
        rule.exceptions = ids
        privacy.setTimeZoneRule(rule)
      }
    }
  }

  private var timeZoneRule: PrivacyRuleValue {
    privacy.effectiveTimeZoneRule
  }

  private var timeZoneAudience: Binding<PrivacyRuleValue.Audience> {
    Binding(
      get: { privacy.effectiveTimeZoneRule.audience },
      set: { audience in
        var rule = privacy.effectiveTimeZoneRule
        rule.audience = audience
        privacy.setTimeZoneRule(rule)
      }
    )
  }

  private var exceptionsButtonTitle: String {
    let count = timeZoneRule.exceptions.count
    return count == 0 ? "Add People…" : (count == 1 ? "1 Person…" : "\(count) People…")
  }
}

#Preview {
  PrivacySettingsDetailView()
}
