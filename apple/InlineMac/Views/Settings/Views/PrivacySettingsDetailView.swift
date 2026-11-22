import InlineKit
import InlineUI
import SwiftUI

struct PrivacySettingsDetailView: View {
  @ObservedObject private var privacy = INUserSettings.current.privacy
  @State private var fileLinkSenders: [LocalFileLinkTrust.Sender] = []
  @State private var isEditingTimeZoneExceptions = false
  @State private var isEditingFocusExceptions = false
  @State private var isPickingTimeZone = false
  @ObservedObject private var focusReporter = FocusStatusReporter.shared

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
        if privacy.supportsManualTimeZone {
          Toggle(isOn: timeZoneAutomatic) {
            SettingsRowLabel(
              .timeZoneAutomatic,
              description: "Use the time zone of your Mac or iPhone. Turn this off to pick one yourself."
            )
          }
          .settingsSearchAnchor(.timeZoneAutomatic)

          if let manualTimeZone = privacy.manualTimeZone {
            LabeledContent("Time Zone") {
              Button("\(manualTimeZone.pickerTitle)…") {
                isPickingTimeZone = true
              }
            }
          }
        }

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

      Section {
        Picker(selection: focusAudience) {
          Text("Everyone").tag(PrivacyRuleValue.Audience.everyone)
          Text("Nobody").tag(PrivacyRuleValue.Audience.nobody)
        } label: {
          SettingsRowLabel(
            .focusStatus,
            description: "Show “Notifications silenced” in direct messages when a Focus is on."
          )
        }
        .settingsSearchAnchor(.focusStatus)

        LabeledContent(focusRule.exceptionsTitle) {
          Button(Self.peopleButtonTitle(focusRule.exceptions.count)) {
            isEditingFocusExceptions = true
          }
        }

        if privacy.sharesFocusStatus {
          focusAccessRow
        }
      } header: {
        SettingsSectionHeader("Focus Status")
      }

      Section {
        Toggle(isOn: $privacy.transcribeVoiceMessages) {
          SettingsRowLabel(
            .transcribeVoiceMessages,
            description: "Voice messages you send are transcribed by an AI service so people can read them. Turn this off to keep your recordings from being sent for transcription."
          )
        }
        .settingsSearchAnchor(.transcribeVoiceMessages)
      } header: {
        SettingsSectionHeader("Voice Messages")
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
    .sheet(isPresented: $isEditingFocusExceptions) {
      PrivacyPeopleEditor(
        title: focusRule.exceptionsTitle,
        footer: focusRule.audience == .everyone
          ? "These people won’t see when your notifications are silenced."
          : "Only these people will see when your notifications are silenced.",
        selectedIDs: focusRule.exceptions
      ) { ids in
        var rule = privacy.effectiveFocusStatusRule
        rule.exceptions = ids
        privacy.setFocusStatusRule(rule)
      }
    }
    .sheet(isPresented: $isPickingTimeZone) {
      ManualTimeZoneSheet(selection: privacy.manualTimeZone) { timeZone in
        privacy.setManualTimeZone(timeZone)
      }
    }
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

  /// Turning automatic off starts from the time zone this Mac is in.
  private var timeZoneAutomatic: Binding<Bool> {
    Binding(
      get: { privacy.manualTimeZone == nil },
      set: { automatic in
        privacy.setManualTimeZone(automatic ? nil : TimeZone.autoupdatingCurrent)
      }
    )
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
    Self.peopleButtonTitle(timeZoneRule.exceptions.count)
  }

  private static func peopleButtonTitle(_ count: Int) -> String {
    count == 0 ? "Add People…" : (count == 1 ? "1 Person…" : "\(count) People…")
  }

  private var focusRule: PrivacyRuleValue {
    privacy.effectiveFocusStatusRule
  }

  private var focusAudience: Binding<PrivacyRuleValue.Audience> {
    Binding(
      get: { privacy.effectiveFocusStatusRule.audience },
      set: { audience in
        var rule = privacy.effectiveFocusStatusRule
        rule.audience = audience
        privacy.setFocusStatusRule(rule)
      }
    )
  }

  /// Apple's own permission, needed before the Mac can read Focus at all.
  @ViewBuilder
  private var focusAccessRow: some View {
    switch focusReporter.authorization {
      case .authorized:
        EmptyView()
      case .notDetermined:
        LabeledContent("This Mac can’t read Focus yet") {
          Button("Allow…") {
            Task { await focusReporter.requestAuthorization() }
          }
        }
      default:
        Text("Allow Inline under Focus › Focus Status in System Settings to share it from this Mac.")
          .font(.callout)
          .foregroundStyle(.secondary)
    }
  }
}

private struct ManualTimeZoneSheet: View {
  @Environment(\.dismiss) private var dismiss
  let selection: TimeZone?
  let onSelect: (TimeZone) -> Void

  var body: some View {
    NavigationStack {
      TimeZonePickerList(selection: selection) { timeZone in
        onSelect(timeZone)
        dismiss()
      }
      .listStyle(.inset)
      .navigationTitle("Time Zone")
      .frame(width: 420, height: 500)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}

#Preview {
  PrivacySettingsDetailView()
}
