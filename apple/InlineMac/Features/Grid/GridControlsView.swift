import AppKit
import InlineKit
import InlineRTC
import InlineMacUI
import SwiftUI

struct GridControlPill: View {
  let media: GridMediaPresentation
  let onToggleMicrophone: () -> Void
  let onLeave: () -> Void
  let onSelectInput: (AudioInputSelection) -> Void
  let onRefreshInputDevices: () -> Void
  let onSetOutputVolume: (Float) -> Void
  let onRetryAudio: () -> Void

  @ViewBuilder
  var body: some View {
    VStack(spacing: 8) {
      if media.providerCircuitOpen {
        GridMediaNotice(
          title: "Voice connection paused",
          actionTitle: "Leave Room",
          action: onLeave
        )
      } else if media.microphonePermission == .denied || media.microphonePermission == .restricted {
        GridMediaNotice(
          title: "Microphone access is off",
          actionTitle: "Open Settings",
          action: openMicrophoneSettings
        )
      } else if case let .failed(message) = media.audioState {
        GridMediaNotice(
          title: message,
          actionTitle: "Try Again",
          action: onRetryAudio
        )
      } else if media.isMicrophoneEnabled, media.localAudioFlowState == .missing {
        GridMediaNotice(
          title: "Microphone audio stopped",
          actionTitle: "Try Again",
          action: onRetryAudio
        )
      } else if media.hasRemoteAudioFlowFailure {
        GridMediaNotice(
          title: "Incoming audio stalled",
          actionTitle: "Try Again",
          action: onRetryAudio
        )
      }
      controlSurface
    }
  }

  @ViewBuilder
  private var controlSurface: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 8) {
        controls
          .glassEffect(.regular, in: Capsule())
      }
    } else {
      controls
        .background(.regularMaterial, in: Capsule())
    }
  }

  private func openMicrophoneSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  private var controls: some View {
    HStack(spacing: 8) {
      GridMicrophoneControl(
        media: media,
        onToggle: onToggleMicrophone,
        onSelectInput: onSelectInput,
        onRefreshInputDevices: onRefreshInputDevices
      )
      GridVolumeControl(media: media, onSetVolume: onSetOutputVolume)
      GridCircularControlButton(help: "Leave room", action: onLeave) {
        Image(systemName: "door.left.hand.open")
          .foregroundStyle(.pink)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
  }
}

private struct GridMediaNotice: View {
  let title: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
      Text(title)
      Button(actionTitle, action: action)
        .buttonStyle(.link)
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: Capsule())
  }
}

private struct GridMicrophoneControl: View {
  let media: GridMediaPresentation
  let onToggle: () -> Void
  let onSelectInput: (AudioInputSelection) -> Void
  let onRefreshInputDevices: () -> Void

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      controls
        .glassEffect(.regular.interactive(), in: Capsule())
    } else {
      controls
        .background(.ultraThinMaterial, in: Capsule())
    }
  }

  private var controls: some View {
    HStack(spacing: 0) {
      Button(action: onToggle) {
        Image(systemName: media.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(media.isMicrophoneEnabled ? Color.green : Color.primary)
          .frame(width: 34, height: 34)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(media.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")

      Rectangle()
        .fill(Color.primary.opacity(0.1))
        .frame(width: 1, height: 17)

      AudioInputDevicePicker(
        selection: Binding(
          get: { media.inputSelection },
          set: onSelectInput
        ),
        automaticDeviceName: media.automaticInputDeviceName,
        devices: media.inputDevices,
        refresh: onRefreshInputDevices
      )
      .frame(width: 23, height: 34)
    }
    .fixedSize()
  }
}

private struct GridVolumeControl: View {
  let media: GridMediaPresentation
  let onSetVolume: (Float) -> Void
  @State private var isPopoverPresented = false

  var body: some View {
    GridCircularControlButton(help: "Grid volume") {
      isPopoverPresented.toggle()
    } label: {
      Image(systemName: volumeSymbol)
        .foregroundStyle(.primary)
    }
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      GridVolumePopover(media: media, onSetVolume: onSetVolume)
    }
  }

  private var volumeSymbol: String {
    if media.outputVolume == 0 { return "speaker.slash.fill" }
    if media.outputVolume < 0.5 { return "speaker.wave.1.fill" }
    return "speaker.wave.2.fill"
  }
}

private struct GridVolumePopover: View {
  let media: GridMediaPresentation
  let onSetVolume: (Float) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Sound")
        .font(.title3.weight(.semibold))
      HStack(spacing: 10) {
        Image(systemName: "speaker.fill")
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { media.outputVolume },
            set: onSetVolume
          ),
          in: 0 ... 1
        )
        Image(systemName: "speaker.wave.3.fill")
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(width: 330)
  }
}

private struct GridCircularControlButton<Label: View>: View {
  let help: String
  let action: () -> Void
  let label: Label

  init(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
    self.help = help
    self.action = action
    self.label = label()
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      button
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      button
        .background(.ultraThinMaterial, in: Circle())
    }
  }

  private var button: some View {
    Button(action: action) {
      label
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
