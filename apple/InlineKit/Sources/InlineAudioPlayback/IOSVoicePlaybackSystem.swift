#if os(iOS)
import AVFAudio
import Combine
import MediaPlayer
import UIKit

/// Process-lifetime system adapter. Updates are event driven; iOS extrapolates elapsed time.
@MainActor
final class IOSVoicePlaybackSystem {
  private weak var center: AudioPlaybackCenter?
  private var cancellables: Set<AnyCancellable> = []
  private var commandTargets: [(MPRemoteCommand, Any)] = []
  private var publishedItem: AudioPlaybackItem?
  private let admission = AudioPlaybackCommandAdmission()

  init(center: AudioPlaybackCenter) {
    self.center = center
    let commands = MPRemoteCommandCenter.shared()
    install(commands.playCommand, command: .play)
    install(commands.pauseCommand, command: .pause)
    install(commands.togglePlayPauseCommand, command: .toggle)
    install(commands.stopCommand, command: .stop)
    let admission = self.admission
    let seekTarget = commands.changePlaybackPositionCommand.addTarget { [weak center, admission] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let time = event.positionTime
      return admission.receive(unavailable: .noSuchContent) { identity in
        Self.onPlaybackActor {
          guard let center else { return .noSuchContent }
          return center.handleRemoteCommand(.seek(time), expectedIdentity: identity) ? .success : .commandFailed
        }
      }
    }
    commandTargets.append((commands.changePlaybackPositionCommand, seekTarget))
    commands.nextTrackCommand.isEnabled = false
    commands.previousTrackCommand.isEnabled = false
    commands.skipForwardCommand.isEnabled = false
    commands.skipBackwardCommand.isEnabled = false
    commands.changePlaybackRateCommand.isEnabled = false
    commands.likeCommand.isEnabled = false
    commands.dislikeCommand.isEnabled = false
    commands.bookmarkCommand.isEnabled = false
    setCommandsEnabled(false)
    observeSystemEvents()
    refreshVisibility()
  }

  func update(eligible: Bool) {
    admission.publish(eligible ? center?.remoteCommandIdentity : nil)
    guard let center, eligible, let item = center.item else {
      // Only clear a publication this adapter owns.
      if publishedItem != nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
      publishedItem = nil
      setCommandsEnabled(false)
      return
    }
    setCommandsEnabled(true)
    publishedItem = item
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: center.display?.title ?? "Voice message",
      MPMediaItemPropertyArtist: center.display?.parentTitle ?? "Inline",
      MPMediaItemPropertyPlaybackDuration: center.duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: center.currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: center.isPlaying ? center.playbackRate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: center.playbackRate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: false,
    ]
  }

  private func install(_ remote: MPRemoteCommand, command: AudioPlaybackCenter.RemoteCommand) {
    let admission = self.admission
    let target = remote.addTarget { [weak center, admission] _ in
      admission.receive(unavailable: .noSuchContent) { identity in
        Self.onPlaybackActor {
          guard let center else { return .noSuchContent }
          return center.handleRemoteCommand(command, expectedIdentity: identity) ? .success : .commandFailed
        }
      }
    }
    commandTargets.append((remote, target))
  }

  private nonisolated static func onPlaybackActor(
    _ body: @Sendable @escaping @MainActor () -> MPRemoteCommandHandlerStatus
  ) -> MPRemoteCommandHandlerStatus {
    if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
  }

  private func setCommandsEnabled(_ enabled: Bool) {
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.isEnabled = enabled
    commands.pauseCommand.isEnabled = enabled
    commands.togglePlayPauseCommand.isEnabled = enabled
    commands.stopCommand.isEnabled = enabled
    commands.changePlaybackPositionCommand.isEnabled = enabled
  }

  private func observeSystemEvents() {
    let notifications = NotificationCenter.default
    if #available(iOS 27.0, *) {
      notifications.publisher(for: AVAudioSession.didBecomeInactiveNotification)
        .sink { [weak self] event in
          guard let context = event.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                context.source == .system else { return }
          Task { @MainActor [weak self] in self?.center?.interruptionBegan() }
        }.store(in: &cancellables)
      notifications.publisher(for: AVAudioSession.resumptionRecommendationNotification)
        .sink { [weak self] event in
          guard let context = event.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
          let shouldResume = context.recommendation == .shouldResume
          Task { @MainActor [weak self] in
            self?.center?.interruptionEnded(
              shouldResume: shouldResume,
              outputAvailable: !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
            )
          }
        }.store(in: &cancellables)
    } else {
      observeLegacyInterruptions()
    }
    notifications.publisher(for: AVAudioSession.routeChangeNotification)
      .sink { [weak self] event in
        let reason = event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        Task { @MainActor [weak self] in self?.center?.outputWasRemoved() }
      }.store(in: &cancellables)
    for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
      notifications.publisher(for: name).sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.center?.mediaServicesWereReset() }
      }.store(in: &cancellables)
    }
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
                 UIScene.didActivateNotification, UIScene.didEnterBackgroundNotification] {
      notifications.publisher(for: name).sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshVisibility() }
      }.store(in: &cancellables)
    }
  }

  @available(iOS, introduced: 18.0, deprecated: 27.0)
  private func observeLegacyInterruptions() {
    let notifications = NotificationCenter.default
    notifications.publisher(for: AVAudioSession.interruptionNotification)
      .sink { [weak self] event in
        let type = (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
        let options = (event.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        Task { @MainActor [weak self] in
          guard let self, let type = type.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
          if type == .began { center?.interruptionBegan() }
          else {
            center?.interruptionEnded(
              shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
              outputAvailable: !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
            )
          }
        }
      }.store(in: &cancellables)
  }

  private func refreshVisibility() {
    center?.setProgressVisible(UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive })
  }
}
#endif
