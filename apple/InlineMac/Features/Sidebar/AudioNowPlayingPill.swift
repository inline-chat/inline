import AppKit
import InlineKit
import Logger
import SwiftUI
import UniformTypeIdentifiers

struct AudioNowPlayingPill: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.appearsActive) private var appearsActive
  private let player = AudioPlaybackCenter.shared

  @State private var isHovering = false

  private static let pillCornerRadius: CGFloat = 13
  static let visibilityAnimation: Animation = .audioPillAppear
  static let visibilityTransition = AnyTransition
    .scale(scale: 0.86, anchor: .bottom)
    .combined(with: .opacity)

  var body: some View {
    if player.item != nil {
      content
    }
  }

  private var content: some View {
    let shape = RoundedRectangle(cornerRadius: Self.pillCornerRadius, style: .continuous)

    return ZStack(alignment: .topLeading) {
      pillBody
        .background(pillBackground(shape: shape))
        .overlay(pillStroke(shape: shape))
        .overlay(alignment: .bottomLeading) {
          AudioPillProgressEdge()
        }
        .compositingGroup()
        .clipShape(shape)

      AudioPillCloseButton(isVisible: isHovering)
        .offset(x: -5, y: -5)
    }
    .padding(.top, 5)
    .padding(.leading, 5)
    .onHover { hovering in
      withAnimation(.audioPillSnap) {
        isHovering = hovering
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
    .contextMenu {
      Button {
        openCurrentItem()
      } label: {
        Label("Show message", systemImage: "text.bubble")
      }
      .disabled(player.openTarget == nil)

      Button {
        saveCurrentAudio()
      } label: {
        Label("Save audio", systemImage: "square.and.arrow.down")
      }
      .disabled(player.sourceURL == nil)
    }
  }

  private var pillBody: some View {
    HStack(spacing: 8) {
      AudioPillPlayPauseButton(foregroundColor: controlTextStyle)

      AudioPillTitleButton(
        display: player.display,
        parentTitle: parentTitle,
        canOpen: player.openTarget != nil,
        primaryColor: primaryTextStyle,
        secondaryColor: secondaryTextStyle,
        action: openCurrentItem
      )

      AudioPillSpeedMenu(foregroundColor: controlTextStyle)

      AudioPillVolumeControl(foregroundColor: controlTextStyle)
    }
    .padding(.horizontal, 9)
    .padding(.top, 6)
    .padding(.bottom, 7)
  }

  @ViewBuilder
  private func pillBackground(shape: RoundedRectangle) -> some View {
    if #available(macOS 26.0, *) {
      shape
        .fill(.clear)
        .glassEffect(.regular.interactive(), in: shape)
    } else {
      shape
        .fill(.ultraThinMaterial)
    }
  }

  private func pillStroke(shape: RoundedRectangle) -> some View {
    shape
      .stroke(Color.primary.opacity(appearsActive ? 0.12 : 0.07), lineWidth: 0.7)
  }

  private var parentTitle: String {
    player.display?.parentTitle ?? player.display?.subtitle ?? "Now playing"
  }

  private var primaryTextStyle: Color {
    .primary
  }

  private var controlTextStyle: Color {
    primaryTextStyle
  }

  private var secondaryTextStyle: Color {
    .secondary
  }

  private var accessibilityLabel: String {
    let title = player.display?.title ?? "Audio"
    return "\(title), \(parentTitle)"
  }

  private func openCurrentItem() {
    guard let target = player.openTarget else { return }
    dependencies?.requestOpenChat(peer: target.peer.inlinePeer, targetMessageId: target.messageId)
  }

  private func saveCurrentAudio() {
    guard let sourceURL = player.sourceURL else { return }
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      ToastCenter.shared.showError("Audio isn't downloaded yet")
      return
    }

    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = Self.allowedContentTypes(for: sourceURL)
    savePanel.nameFieldStringValue = Self.defaultSaveFileName(sourceURL: sourceURL, item: player.item)
    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    savePanel.canCreateDirectories = true

    savePanel.begin { response in
      guard response == .OK, let destinationURL = savePanel.url else { return }
      Self.copyAudio(from: sourceURL, to: destinationURL)
    }
  }

  private static func defaultSaveFileName(sourceURL: URL, item: AudioPlaybackItem?) -> String {
    let sourceName = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if sourceName.isEmpty == false {
      return sourceName
    }

    let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackExtension = fileExtension.isEmpty ? "m4a" : fileExtension
    if let item {
      return "audio_\(item.mediaId).\(fallbackExtension)"
    }
    return "audio.\(fallbackExtension)"
  }

  private static func allowedContentTypes(for sourceURL: URL) -> [UTType] {
    let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    guard fileExtension.isEmpty == false, let type = UTType(filenameExtension: fileExtension) else {
      return [.audio]
    }
    return [type, .audio]
  }

  private static func copyAudio(from sourceURL: URL, to destinationURL: URL) {
    let fileManager = FileManager.default
    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }

      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      Task { @MainActor in
        ToastCenter.shared.showSuccess("Audio saved")
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
      }
    } catch {
      Log.shared.error("Failed to save now-playing audio", error: error)
      Task { @MainActor in
        ToastCenter.shared.showError("Failed to save audio")
      }
    }
  }
}

private struct AudioPillPlayPauseButton: View {
  let foregroundColor: Color
  private let player = AudioPlaybackCenter.shared

  var body: some View {
    Button(action: togglePlayback) {
      Image(systemName: symbolName)
        .font(.system(size: 11, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(foregroundColor)
        .frame(width: 20, height: 20)
        .contentShape(Circle())
        .animation(.audioPillSnap, value: symbolName)
    }
    .buttonStyle(AudioPillPressButtonStyle())
    .help(accessibilityLabel)
    .accessibilityLabel(accessibilityLabel)
  }

  private var symbolName: String {
    player.isPlaying ? "pause.fill" : "play.fill"
  }

  private var accessibilityLabel: String {
    player.isPlaying ? "Pause audio" : "Play audio"
  }

  private func togglePlayback() {
    withAnimation(.audioPillSnap) {
      try? player.toggleCurrentPlayback()
    }
  }
}

private struct AudioPillTitleButton: View {
  let display: AudioPlaybackDisplay?
  let parentTitle: String
  let canOpen: Bool
  let primaryColor: Color
  let secondaryColor: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 1) {
        Text(display?.title ?? "Audio")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(primaryColor)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(parentTitle)
          .font(.system(size: 10.5))
          .foregroundStyle(secondaryColor)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(canOpen == false)
    .help("Open audio message")
    .accessibilityLabel("Open audio message")
  }
}

private struct AudioPillSpeedMenu: View {
  let foregroundColor: Color
  private let player = AudioPlaybackCenter.shared
  private static let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

  var body: some View {
    Menu {
      ForEach(Self.playbackRates, id: \.self) { rate in
        Button(rateTitle(rate)) {
          player.setPlaybackRate(rate)
        }
      }
    } label: {
      Text(rateTitle(player.playbackRate))
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(foregroundColor)
        .frame(width: 34, alignment: .trailing)
    }
    .menuStyle(.button)
    .buttonStyle(AudioPillPressButtonStyle())
    .menuIndicator(.hidden)
    .help("Playback speed")
    .accessibilityLabel("Playback speed")
  }

  private func rateTitle(_ rate: Float) -> String {
    switch rate {
    case 0.75:
      "0.75x"
    case 1:
      "1x"
    case 1.25:
      "1.25x"
    case 1.5:
      "1.5x"
    case 2:
      "2x"
    default:
      String(format: "%.2gx", Double(rate))
    }
  }
}

private struct AudioPillVolumeControl: View {
  let foregroundColor: Color
  private let player = AudioPlaybackCenter.shared

  @State private var isPopoverPresented = false

  var body: some View {
    Button {
      withAnimation(.audioPillSnap) {
        isPopoverPresented.toggle()
      }
    } label: {
      Image(systemName: Self.symbolName(for: Double(player.volume)))
        .font(.system(size: 11, weight: .medium))
        .symbolRenderingMode(.monochrome)
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(foregroundColor)
        .frame(width: 18, height: 20)
        .contentShape(Circle())
        .animation(.audioPillSnap, value: Self.symbolName(for: Double(player.volume)))
    }
    .buttonStyle(AudioPillPressButtonStyle())
    .audioPillInteractiveCircle(isProminent: isPopoverPresented)
    .help("Volume")
    .accessibilityLabel("Volume")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      AudioPillVolumePopover(
        foregroundColor: foregroundColor,
        initialVolume: Double(player.volume)
      )
    }
  }

  private static func symbolName(for volume: Double) -> String {
    switch volume {
    case ...0:
      "speaker.slash.fill"
    case ..<0.5:
      "speaker.wave.1.fill"
    default:
      "speaker.wave.2.fill"
    }
  }
}

private struct AudioPillVolumePopover: View {
  let foregroundColor: Color
  private let player = AudioPlaybackCenter.shared

  @State private var isEditing = false
  @State private var sliderVolume: Double

  init(foregroundColor: Color, initialVolume: Double) {
    self.foregroundColor = foregroundColor
    _sliderVolume = State(initialValue: initialVolume)
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "speaker.wave.1.fill")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(foregroundColor)

      Slider(
        value: Binding(
          get: { sliderVolume },
          set: updateSliderVolume
        ),
        in: 0 ... 1,
        onEditingChanged: handleEditingChanged
      )
      .controlSize(.small)
      .frame(width: 128)
      .accessibilityLabel("Volume")

      Image(systemName: "speaker.wave.2.fill")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(foregroundColor)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(popoverBackground)
    .onDisappear {
      commitVolume()
    }
  }

  @ViewBuilder
  private var popoverBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    if #available(macOS 26.0, *) {
      shape
        .fill(.clear)
        .glassEffect(.regular.interactive(), in: shape)
    } else {
      shape
        .fill(.clear)
    }
  }

  private func updateSliderVolume(_ value: Double) {
    let clamped = min(max(value, 0), 1)
    guard abs(sliderVolume - clamped) > 0.001 else { return }
    sliderVolume = clamped
    player.previewVolume(Float(clamped))
  }

  private func handleEditingChanged(_ editing: Bool) {
    isEditing = editing
    if editing == false {
      commitVolume()
    }
  }

  private func commitVolume() {
    player.setVolume(Float(sliderVolume))
  }
}

private struct AudioPillProgressEdge: View {
  private let player = AudioPlaybackCenter.shared

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottomLeading) {
        Color.clear
          .frame(height: 12)

        Rectangle()
          .fill(Color.accentColor.opacity(0.86))
          .frame(width: max(0, proxy.size.width * playbackProgress))
          .frame(height: 2.5)
          .animation(.linear(duration: 0.075), value: playbackProgress)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard proxy.size.width > 0 else { return }
            player.seek(to: value.location.x / proxy.size.width)
          }
      )
    }
    .frame(height: 12)
    .allowsHitTesting(player.duration > 0)
  }

  private var playbackProgress: Double {
    guard player.duration > 0 else { return 0 }
    return min(max(player.currentTime / player.duration, 0), 1)
  }
}

private struct AudioPillCloseButton: View {
  let isVisible: Bool
  private let player = AudioPlaybackCenter.shared

  var body: some View {
    Group {
      if isVisible {
        button
          .transition(.scale(scale: 0.82).combined(with: .opacity))
      }
    }
    .animation(.audioPillSnap, value: isVisible)
  }

  @ViewBuilder
  private var button: some View {
    let button = Button(action: close) {
      Image(systemName: "xmark")
        .font(.system(size: 8.5, weight: .bold))
        .foregroundStyle(Color.primary.opacity(0.72))
        .frame(width: 17, height: 17)
        .contentShape(Circle())
    }
    .buttonStyle(AudioPillPressButtonStyle())
    .help("Close audio")
    .accessibilityLabel("Close audio")

    if #available(macOS 26.0, *) {
      button
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      button
        .background(.ultraThinMaterial, in: Circle())
        .overlay(
          Circle()
            .stroke(Color.primary.opacity(0.18), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
    }
  }

  private func close() {
    withAnimation(.audioPillSnap) {
      player.close()
    }
  }
}

private struct AudioPillPressButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .opacity(configuration.isPressed ? 0.68 : 1)
      .animation(.audioPillPress, value: configuration.isPressed)
  }
}

private struct AudioPillInteractiveCircleModifier: ViewModifier {
  let isProminent: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    let shape = Circle()

    if #available(macOS 26.0, *) {
      content
        .padding(2)
        .glassEffect(.regular.interactive(), in: shape)
        .overlay {
          shape
            .stroke(.white.opacity(isProminent ? 0.22 : 0), lineWidth: 0.8)
        }
        .animation(.audioPillSnap, value: isProminent)
    } else {
      content
    }
  }
}

private extension View {
  func audioPillInteractiveCircle(isProminent: Bool = false) -> some View {
    modifier(AudioPillInteractiveCircleModifier(isProminent: isProminent))
  }
}

private extension Animation {
  static var audioPillAppear: Animation {
    .spring(response: 0.18, dampingFraction: 0.76, blendDuration: 0.02)
  }

  static var audioPillSnap: Animation {
    .spring(response: 0.14, dampingFraction: 0.72, blendDuration: 0.01)
  }

  static var audioPillPress: Animation {
    .spring(response: 0.1, dampingFraction: 0.7, blendDuration: 0)
  }
}
