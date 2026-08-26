import InlineRTC
import SwiftUI

struct AudioAndVideoSettingsDetailView: View {
  @Environment(GridRoomService.self) private var grid

  var body: some View {
    Form {
      AudioAndVideoDeviceSettingsSection(grid: grid)
      GridAudioSettingsSection(grid: grid)
    }
    .settingsFormStyle()
    .onAppear {
      grid.refreshInputDevices()
      grid.refreshOutputDevices()
    }
  }
}

private struct AudioAndVideoDeviceSettingsSection: View {
  let grid: GridRoomService

  var body: some View {
    Section {
      AudioInputSettingsRow(grid: grid)
      AudioOutputSettingsRow(grid: grid)
    } header: {
      SettingsSectionHeader("Devices")
    }
  }
}

private struct AudioInputSettingsRow: View {
  let grid: GridRoomService

  var body: some View {
    @Bindable var grid = grid

    LabeledContent {
      Picker("Input Device", selection: $grid.inputSelection) {
        Text(automaticDeviceLabel)
          .tag(AudioInputSelection.automatic)

        ForEach(grid.media.inputDevices) { device in
          Text(device.name)
            .tag(selection(for: device))
        }

        if case let .device(_, rememberedName) = grid.inputSelection,
           grid.inputSelection.resolvedDeviceID(in: grid.media.inputDevices) == nil {
          Text("\(rememberedName) — Unavailable")
            .tag(grid.inputSelection)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
    } label: {
      SettingsRowLabel("Input Device")
    }
  }

  private var automaticDeviceLabel: String {
    let name = grid.media.automaticInputDeviceName
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != "System Default" else {
      return String(localized: "System Default")
    }
    return String(localized: "System Default — \(name)")
  }

  private func selection(for device: AudioInputDeviceDescriptor) -> AudioInputSelection {
    if grid.inputSelection.matches(device, among: grid.media.inputDevices) {
      return grid.inputSelection
    }
    return .device(id: device.id, rememberedName: device.name)
  }
}

private struct AudioOutputSettingsRow: View {
  let grid: GridRoomService

  var body: some View {
    @Bindable var grid = grid

    LabeledContent {
      Picker("Output Device", selection: $grid.outputSelection) {
        Text(automaticDeviceLabel)
          .tag(AudioOutputSelection.automatic)

        ForEach(grid.media.outputDevices) { device in
          Text(device.name)
            .tag(selection(for: device))
        }

        if case let .device(_, rememberedName) = grid.outputSelection,
           grid.outputSelection.resolvedDeviceID(in: grid.media.outputDevices) == nil {
          Text("\(rememberedName) — Unavailable")
            .tag(grid.outputSelection)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .fixedSize()
    } label: {
      SettingsRowLabel("Output Device")
    }
  }

  private var automaticDeviceLabel: String {
    let name = grid.media.automaticOutputDeviceName
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != "System Default" else {
      return String(localized: "System Default")
    }
    return String(localized: "System Default — \(name)")
  }

  private func selection(for device: AudioOutputDeviceDescriptor) -> AudioOutputSelection {
    if grid.outputSelection.matches(device, among: grid.media.outputDevices) {
      return grid.outputSelection
    }
    return .device(id: device.id, rememberedName: device.name)
  }
}

private struct GridAudioSettingsSection: View {
  let grid: GridRoomService

  var body: some View {
    @Bindable var grid = grid

    Section {
      Toggle(isOn: $grid.autoUnmuteOnJoin) {
        SettingsRowLabel(
          "Auto-Unmute on Join",
          description: "Open your microphone when you deliberately join a room."
        )
      }

      Toggle(isOn: $grid.autoMuteWhenAlone) {
        SettingsRowLabel(
          "Auto-Mute When Alone",
          description: "Mute your microphone after you are alone for five seconds."
        )
      }
    } header: {
      SettingsSectionHeader("Grid")
    }
  }
}

#Preview {
  AudioAndVideoSettingsDetailView()
    .previewsEnvironment(.populated)
}
