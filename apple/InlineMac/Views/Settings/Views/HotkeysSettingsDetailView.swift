import InlineMacUI
import SwiftUI

struct HotkeysSettingsDetailView: View {
  @StateObject private var hotkeySettings = HotkeySettingsStore.shared
  @State private var recordingAction: HotkeyAction?
  @State private var recordingError: String?

  var body: some View {
    Form {
      Section {
        GlobalHotkeySettingsRow(
          title: "Focus Inline",
          description: "Bring Inline to the front from any app.",
          configuration: $hotkeySettings.globalFocusHotkey,
          isRecording: recordingAction == .focusInline,
          onRecord: { toggleRecording(.focusInline) },
          onClear: { clear(.focusInline) }
        )

        GlobalHotkeySettingsRow(
          title: "Grid Microphone",
          description: "Mute or unmute your microphone in the active Grid room from any app.",
          configuration: $hotkeySettings.gridMicrophoneHotkey,
          isRecording: recordingAction == .gridMicrophone,
          onRecord: { toggleRecording(.gridMicrophone) },
          onClear: { clear(.gridMicrophone) }
        )

        if let recordingError {
          Text(recordingError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } header: {
        SettingsSectionHeader(
          "Global Hotkeys",
          subtitle: "Some shortcuts are reserved by macOS and may not be available."
        )
      }
    }
    .settingsFormStyle()
    .background {
      // Captures key presses while recording.
      KeyPressHandler { event in
        guard let recordingAction else { return event }

        // Escape cancels.
        if event.keyCode == 53 {
          self.recordingAction = nil
          recordingError = nil
          return nil
        }

        guard let hotkey = InlineHotkey.fromKeyDownEvent(event) else {
          return nil
        }

        guard let conflictingAction = conflictingAction(for: hotkey, excluding: recordingAction) else {
          set(hotkey, for: recordingAction)
          self.recordingAction = nil
          recordingError = nil
          return nil
        }

        recordingError = "That shortcut is already assigned to \(conflictingAction.displayName)."
        return nil
      }
      // Avoid taking layout space.
      .frame(width: 0, height: 0)
    }
  }

  private func toggleRecording(_ action: HotkeyAction) {
    recordingAction = recordingAction == action ? nil : action
    recordingError = nil
  }

  private func set(_ hotkey: InlineHotkey, for action: HotkeyAction) {
    let configuration = HotkeySettingsStore.HotkeyConfiguration(enabled: true, hotkey: hotkey)
    set(configuration, for: action)
  }

  private func clear(_ action: HotkeyAction) {
    set(.init(enabled: false, hotkey: nil), for: action)
    if recordingAction == action {
      recordingAction = nil
    }
    recordingError = nil
  }

  private func set(_ configuration: HotkeySettingsStore.HotkeyConfiguration, for action: HotkeyAction) {
    switch action {
    case .focusInline:
      hotkeySettings.globalFocusHotkey = configuration
    case .gridMicrophone:
      hotkeySettings.gridMicrophoneHotkey = configuration
    }
  }

  private func conflictingAction(for hotkey: InlineHotkey, excluding action: HotkeyAction) -> HotkeyAction? {
    for candidate in HotkeyAction.allCases where candidate != action {
      let configuredHotkey = switch candidate {
      case .focusInline:
        hotkeySettings.globalFocusHotkey.hotkey
      case .gridMicrophone:
        hotkeySettings.gridMicrophoneHotkey.hotkey
      }
      if configuredHotkey == hotkey {
        return candidate
      }
    }
    return nil
  }
}

private enum HotkeyAction: CaseIterable, Equatable {
  case focusInline
  case gridMicrophone

  var displayName: String {
    switch self {
    case .focusInline: "Focus Inline"
    case .gridMicrophone: "Grid Microphone"
    }
  }
}

private struct GlobalHotkeySettingsRow: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  @Binding var configuration: HotkeySettingsStore.HotkeyConfiguration
  let isRecording: Bool
  let onRecord: () -> Void
  let onClear: () -> Void

  var body: some View {
    LabeledContent {
      HStack(alignment: .center, spacing: 8) {
        Toggle("Enabled", isOn: $configuration.enabled)
          .labelsHidden()
          .disabled(configuration.hotkey == nil)

        Text(currentHotkeyLabel)
          .foregroundStyle(.secondary)
          .monospaced()
          .lineLimit(1)
          .truncationMode(.tail)

        Button(isRecording ? "Recording" : "Set", action: onRecord)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)

        Button("Clear", action: onClear)
          .disabled(configuration.hotkey == nil && !configuration.enabled)
      }
    } label: {
      SettingsRowLabel(title, description: description)
    }
  }

  private var currentHotkeyLabel: String {
    if isRecording {
      return "Type shortcut (Esc to cancel)"
    }
    if let hotkey = configuration.hotkey {
      return hotkey.displayString
    }
    return "Not set"
  }
}

#Preview {
  HotkeysSettingsDetailView()
}
