import InlineMacUI
import SwiftUI

struct HotkeysSettingsDetailView: View {
  @StateObject private var hotkeySettings = HotkeySettingsStore.shared
  @State private var isRecordingFocusHotkey = false

  var body: some View {
    Form {
      Section {
        Toggle("Enable global hotkey", isOn: enabledBinding)

        HStack(alignment: .center, spacing: 12) {
          Text("Focus Inline")

          Spacer()

          Text(currentHotkeyLabel)
            .foregroundStyle(.secondary)
            .monospaced()
            .lineLimit(1)
            .truncationMode(.tail)

          Button(isRecordingFocusHotkey ? "Recording" : "Set") {
            isRecordingFocusHotkey.toggle()
          }
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)

          Button("Clear") {
            isRecordingFocusHotkey = false
            hotkeySettings.globalFocusHotkey = .init(enabled: false, hotkey: nil)
          }
          .disabled(hotkeySettings.globalFocusHotkey.hotkey == nil && !hotkeySettings.globalFocusHotkey.enabled)
        }
      } header: {
        Text("Global")
      } footer: {
        Text("When pressed, Inline comes to the front and focuses its main window. Some shortcuts are reserved by macOS and may not be registerable.")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
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
        if updated.enabled, updated.hotkey == nil {
          // Keep it enabled but require the user to set a shortcut.
        }
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
