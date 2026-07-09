import InlineMacUI
import SwiftUI

struct HotkeysSettingsDetailView: View {
  @StateObject private var hotkeySettings = HotkeySettingsStore.shared
  @State private var isRecordingFocusHotkey = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: enabledBinding) {
          SettingsRowLabel(
            "Enable Global Hotkey",
            description: "Allow a keyboard shortcut to bring Inline to the front from any app."
          )
        }

        LabeledContent {
          HStack(alignment: .center, spacing: 8) {
            Text(currentHotkeyLabel)
              .foregroundStyle(.secondary)
              .monospaced()
              .lineLimit(1)
              .truncationMode(.tail)

            Button {
              isRecordingFocusHotkey.toggle()
            } label: {
              if isRecordingFocusHotkey {
                Text("Recording")
              } else {
                Text("Set")
              }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            Button("Clear") {
              isRecordingFocusHotkey = false
              hotkeySettings.globalFocusHotkey = .init(enabled: false, hotkey: nil)
            }
            .disabled(hotkeySettings.globalFocusHotkey.hotkey == nil && !hotkeySettings.globalFocusHotkey.enabled)
          }
        } label: {
          SettingsRowLabel(
            "Focus Inline",
            description: "Some shortcuts are reserved by macOS and may not be available."
          )
        }
      } header: {
        SettingsSectionHeader("Global Hotkey")
      }
    }
    .settingsFormStyle()
    .background {
      // Captures key presses while recording.
      KeyPressHandler { event in
        guard isRecordingFocusHotkey else { return event }

        // Escape cancels.
        if event.keyCode == 53 {
          isRecordingFocusHotkey = false
          return nil
        }

        guard let hotkey = InlineHotkey.fromKeyDownEvent(event) else {
          return nil
        }

        isRecordingFocusHotkey = false
        hotkeySettings.globalFocusHotkey = .init(enabled: true, hotkey: hotkey)
        return nil
      }
      // Avoid taking layout space.
      .frame(width: 0, height: 0)
    }
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { hotkeySettings.globalFocusHotkey.enabled },
      set: { newValue in
        var updated = hotkeySettings.globalFocusHotkey
        updated.enabled = newValue
        hotkeySettings.globalFocusHotkey = updated
      }
    )
  }

  private var currentHotkeyLabel: String {
    if isRecordingFocusHotkey {
      return "Type shortcut (Esc to cancel)"
    }
    if let hk = hotkeySettings.globalFocusHotkey.hotkey {
      return hk.displayString
    }
    return "Not set"
  }
}

#Preview {
  HotkeysSettingsDetailView()
}
