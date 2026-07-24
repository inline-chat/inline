import AppKit
import CoreGraphics
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
  let onSelectOutput: (AudioOutputSelection) -> Void
  let onRefreshOutputDevices: () -> Void
  let onToggleScreenShare: () -> Void
  let onSelectScreenCaptureSource: (InlineRTCScreenCaptureSource) -> Void
  let onRefreshScreenCaptureSources: () -> Void
  let onStopScreenShare: () -> Void
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
      } else if let screenCaptureError = media.screenCaptureError {
        GridMediaNotice(
          title: screenCaptureNoticeTitle(screenCaptureError),
          actionTitle: screenCaptureNoticeActionTitle,
          action: screenCaptureNoticeAction
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

  private func openScreenRecordingSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  private func screenCaptureNoticeTitle(_ error: String) -> String {
    guard CGPreflightScreenCaptureAccess() else {
      return "Screen Recording access is off"
    }
    switch media.screenCaptureIssue {
    case .sourceDiscovery:
      return "Displays couldn’t be loaded"
    case .sharing:
      if error == "Screen sharing stopped" {
        return error
      }
      if error == "Screen sharing did not stop" {
        return "Screen sharing couldn’t be stopped safely"
      }
      return "Screen sharing couldn’t start"
    case nil:
      return error
    }
  }

  private var screenCaptureNoticeActionTitle: String {
    guard CGPreflightScreenCaptureAccess() else { return "Open Settings" }
    if media.screenCaptureError == "Screen sharing did not stop" {
      return "Leave Room"
    }
    return media.screenCaptureIssue == .sharing ? "Share Again" : "Refresh"
  }

  private func screenCaptureNoticeAction() {
    guard CGPreflightScreenCaptureAccess() else {
      openScreenRecordingSettings()
      return
    }
    if media.screenCaptureError == "Screen sharing did not stop" {
      onLeave()
      return
    }
    if media.screenCaptureIssue == .sharing {
      onToggleScreenShare()
    } else {
      onRefreshScreenCaptureSources()
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      GridMicrophoneControl(
        media: media,
        onToggle: onToggleMicrophone,
        onSelectInput: onSelectInput,
        onRefreshInputDevices: onRefreshInputDevices
      )
      GridScreenShareControl(
        media: media,
        onToggle: onToggleScreenShare,
        onSelectSource: onSelectScreenCaptureSource,
        onRefreshSources: onRefreshScreenCaptureSources,
        onStop: onStopScreenShare
      )
      GridVolumeControl(
        media: media,
        onSelectOutput: onSelectOutput,
        onRefreshOutputDevices: onRefreshOutputDevices,
        onSetVolume: onSetOutputVolume
      )
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

private struct GridTintedControlIcon: View {
  let systemName: String
  let isActive: Bool

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(isActive ? Color.white : Color.primary)
      .frame(width: 34, height: 34)
      .background(isActive ? Color.green : Color.clear, in: Circle())
      .contentShape(Rectangle())
      .animation(.easeOut(duration: 0.15), value: isActive)
  }
}

struct GridScreenShareActivityIndicator: View {
  let tint: Color
  var size: CGFloat = 12

  @State private var angle: Double = 0

  var body: some View {
    Circle()
      .trim(from: 0.16, to: 0.86)
      .stroke(
        tint,
        style: StrokeStyle(lineWidth: 2, lineCap: .round)
      )
      .frame(width: size, height: size)
      .rotationEffect(.degrees(angle))
      .onAppear {
        angle = 0
        withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
          angle = 360
        }
      }
      .accessibilityHidden(true)
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
        GridTintedControlIcon(
          systemName: media.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
          isActive: media.isMicrophoneEnabled
        )
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

private struct GridScreenShareControl: View {
  let media: GridMediaPresentation
  let onToggle: () -> Void
  let onSelectSource: (InlineRTCScreenCaptureSource) -> Void
  let onRefreshSources: () -> Void
  let onStop: () -> Void

  @State private var isPickerPresented = false

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
        screenShareIcon
      }
      .buttonStyle(.plain)
      .help(screenShareControlLabel)
      .accessibilityLabel(screenShareControlLabel)

      Rectangle()
        .fill(Color.primary.opacity(0.1))
        .frame(width: 1, height: 17)

      Button {
        isPickerPresented = true
        onRefreshSources()
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 23, height: 34)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
        GridScreenCapturePicker(
          media: media,
          onSelectSource: {
            onSelectSource($0)
            isPickerPresented = false
          },
          onRefreshSources: onRefreshSources,
          onStop: {
            onStop()
            isPickerPresented = false
          }
        )
      }
      .help("Choose a display")
      .accessibilityLabel("Choose a display to share")
    }
    .fixedSize()
    .disabled(isStoppingScreenShare || isLoadingScreenCaptureSources)
  }

  @ViewBuilder
  private var screenShareIcon: some View {
    if isTransitioningScreenShare {
      GridScreenShareActivityIndicator(tint: .green)
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
    } else {
      GridTintedControlIcon(
        systemName: media.isScreenSharing
          ? "rectangle.on.rectangle.fill"
          : "rectangle.on.rectangle",
        isActive: media.isScreenSharing
      )
    }
  }

  private var screenShareControlLabel: String {
    if isLoadingScreenCaptureSources {
      return "Loading displays"
    }
    switch media.screenShareState {
    case .publishing:
      return "Cancel screen sharing"
    case .stopping:
      return "Stopping screen sharing"
    default:
      if media.isScreenShareRequested, !media.isScreenSharing {
        return "Cancel screen sharing"
      } else {
        return media.isScreenSharing || media.isScreenShareRequested
          ? "Stop sharing screen"
          : "Share screen"
      }
    }
  }

  private var isTransitioningScreenShare: Bool {
    if isLoadingScreenCaptureSources {
      return true
    }
    switch media.screenShareState {
    case .publishing, .stopping:
      return true
    default:
      return media.isScreenShareRequested && !media.isScreenSharing
    }
  }

  private var isStoppingScreenShare: Bool {
    if case .stopping = media.screenShareState { return true }
    return false
  }

  private var isLoadingScreenCaptureSources: Bool {
    media.isRefreshingScreenCaptureSources && !media.isScreenShareRequested
  }
}

private struct GridScreenCapturePicker: View {
  let media: GridMediaPresentation
  let onSelectSource: (InlineRTCScreenCaptureSource) -> Void
  let onRefreshSources: () -> Void
  let onStop: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Displays")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)

      if media.isRefreshingScreenCaptureSources {
        HStack(spacing: 8) {
          GridScreenShareActivityIndicator(tint: Color.primary.opacity(0.55))
          Text("Loading displays…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
      } else if media.screenCaptureSources.isEmpty {
        Text("No displays available")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
      } else {
        ForEach(media.screenCaptureSources) { source in
          Button {
            onSelectSource(source)
          } label: {
            HStack(spacing: 8) {
              GridDisplayTopologyIcon(
                highlightedSource: source,
                sources: media.screenCaptureSources
              )
              Text(source.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
              if media.selectedScreenCaptureSource?.id == source.id {
                Image(systemName: "checkmark")
                  .foregroundStyle(.green)
              }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .frame(height: 30)
          }
          .buttonStyle(.plain)
          .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
      }

      Divider()

      HStack(spacing: 8) {
        if media.isScreenSharing || media.isScreenShareRequested {
          Button("Stop Sharing", role: .destructive, action: onStop)
        }
        Button("Refresh", systemImage: "arrow.clockwise", action: onRefreshSources)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .padding(12)
    .frame(width: 340)
  }
}

private struct GridDisplayTopologyIcon: View {
  let highlightedSource: InlineRTCScreenCaptureSource
  let sources: [InlineRTCScreenCaptureSource]

  var body: some View {
    GeometryReader { geometry in
      let displaySources = sources.filter { $0.kind == .display }
      let bounds = topologyBounds(for: displaySources)
      ZStack {
        ForEach(displaySources) { source in
          let isHighlighted = source.id == highlightedSource.id
          let rect = topologyRect(
            for: source.frame,
            in: bounds,
            size: geometry.size
          )
          RoundedRectangle(cornerRadius: 1.5)
            .fill(
              isHighlighted
                ? Color.green.opacity(0.72)
                : Color.gray.opacity(0.24)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(
                  isHighlighted ? Color.green : Color.gray.opacity(0.7),
                  lineWidth: isHighlighted ? 1.5 : 1
                )
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .zIndex(isHighlighted ? 1 : 0)
        }
      }
    }
    .frame(width: 42, height: 24)
    .accessibilityHidden(true)
  }

  private func topologyBounds(
    for sources: [InlineRTCScreenCaptureSource]
  ) -> InlineRTCScreenCaptureSource.Frame {
    guard let first = sources.first else {
      return InlineRTCScreenCaptureSource.Frame(x: 0, y: 0, width: 1, height: 1)
    }
    let minX = sources.reduce(first.frame.x) { min($0, $1.frame.x) }
    let minY = sources.reduce(first.frame.y) { min($0, $1.frame.y) }
    let maxX = sources.reduce(first.frame.x + first.frame.width) {
      max($0, $1.frame.x + $1.frame.width)
    }
    let maxY = sources.reduce(first.frame.y + first.frame.height) {
      max($0, $1.frame.y + $1.frame.height)
    }
    return InlineRTCScreenCaptureSource.Frame(
      x: minX,
      y: minY,
      width: max(maxX - minX, 1),
      height: max(maxY - minY, 1)
    )
  }

  private func topologyRect(
    for frame: InlineRTCScreenCaptureSource.Frame,
    in bounds: InlineRTCScreenCaptureSource.Frame,
    size: CGSize
  ) -> CGRect {
    let scale = min(
      size.width / CGFloat(bounds.width),
      size.height / CGFloat(bounds.height)
    )
    let renderedWidth = CGFloat(bounds.width) * scale
    let renderedHeight = CGFloat(bounds.height) * scale
    let xOffset = (size.width - renderedWidth) / 2
    let yOffset = (size.height - renderedHeight) / 2
    let x = xOffset + CGFloat(frame.x - bounds.x) * scale
    let y = yOffset + CGFloat(frame.y - bounds.y) * scale
    return CGRect(
      x: x,
      y: y,
      width: max(CGFloat(frame.width) * scale, 4),
      height: max(CGFloat(frame.height) * scale, 4)
    )
  }
}

private struct GridVolumeControl: View {
  let media: GridMediaPresentation
  let onSelectOutput: (AudioOutputSelection) -> Void
  let onRefreshOutputDevices: () -> Void
  let onSetVolume: (Float) -> Void
  @State private var isPopoverPresented = false

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
      Button {
        isPopoverPresented.toggle()
      } label: {
        Image(systemName: volumeSymbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 34, height: 34)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Grid volume")
      .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
        GridVolumePopover(media: media, onSetVolume: onSetVolume)
      }

      Rectangle()
        .fill(Color.primary.opacity(0.1))
        .frame(width: 1, height: 17)

      AudioOutputDevicePicker(
        selection: Binding(
          get: { media.outputSelection },
          set: onSelectOutput
        ),
        automaticDeviceName: media.automaticOutputDeviceName,
        devices: media.outputDevices,
        refresh: onRefreshOutputDevices
      )
      .frame(width: 23, height: 34)
    }
    .fixedSize()
  }

  private var volumeSymbol: String {
    if media.outputVolume == 0 { return "speaker.slash.fill" }
    if let activeOutputDeviceID = media.activeOutputDeviceID,
       let activeOutput = media.outputDevices.first(where: { $0.id == activeOutputDeviceID }),
       !activeOutput.systemImage.hasPrefix("speaker.") {
      return activeOutput.systemImage
    }
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
