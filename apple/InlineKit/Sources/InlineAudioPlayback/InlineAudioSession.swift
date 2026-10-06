import Foundation
import Observation
#if os(iOS)
import AVFAudio
#endif

/// A generation fence for the few Inline features that share the process audio session.
/// It does not own players or decide when they should resume.
@MainActor
@Observable
public final class InlineAudioSession {
  public static let shared = InlineAudioSession()

  public enum Owner: Equatable, Sendable {
    case voice, recording, draftPreview, video, call
  }

  public struct Token: Equatable, Sendable {
    public let owner: Owner
    fileprivate let generation: UInt64
  }

  public private(set) var current: Token?
  @ObservationIgnored public var willAcquire: ((Owner) -> Void)?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private let deactivate: () -> Void
  @ObservationIgnored private let backend: (any InlineAudioSessionBackend)?
  @ObservationIgnored private var transitionTail: Task<Void, Never>?

  public private(set) var isQuarantined = false
  public private(set) var isSpeakerPreferred = false
  public private(set) var isSpeakerOutputActive = false
  public private(set) var currentRouteName = "Audio"
  public private(set) var supportsReceiverRouting = false
  public var isGridActive: Bool {
    gridToken != nil
  }

  @ObservationIgnored private var gridToken: Token?
  @ObservationIgnored private var gridEpoch: UInt64 = 0
  @ObservationIgnored private var gridRequestedEpoch: UInt64 = 0
  @ObservationIgnored private var gridDemandActive = false
  @ObservationIgnored private var gridMediaQuiescent = true
  @ObservationIgnored private var gridDirectionsIdle = true
  @ObservationIgnored private var gridNativeActive = false
  @ObservationIgnored private var gridTransitions = 0
  @ObservationIgnored private var gridRetiring = false
  @ObservationIgnored private var gridRetirementTask: Task<Void, Never>?
  @ObservationIgnored private var gridRestartRequired = false

  struct Configuration: Sendable {
    let category: String
    let mode: String
    let options: UInt
    var preferredIOBufferDuration: TimeInterval?
    var usesAutomaticInput = false

    static let voicePlayback = Configuration(
      category: "AVAudioSessionCategoryPlayback", mode: "AVAudioSessionModeSpokenAudio", options: 0
    )

    static let gridVoice: Configuration = {
      #if os(iOS)
      let options = AVAudioSession.CategoryOptions.allowBluetoothHFP.rawValue
      #else
      let options: UInt = 0
      #endif
      return Configuration(
        category: "AVAudioSessionCategoryPlayAndRecord", mode: "AVAudioSessionModeVoiceChat",
        options: options, preferredIOBufferDuration: 0.02, usesAutomaticInput: true
      )
    }()
  }

  var requiresNativeTransition: Bool {
    backend != nil
  }

  public init(deactivate: @escaping () -> Void = {}) {
    self.deactivate = deactivate
    #if os(iOS)
    backend = NativeAudioSessionBackend()
    #else
    backend = nil
    #endif
  }

  init(backend: any InlineAudioSessionBackend, deactivate: @escaping () -> Void = {}) {
    self.backend = backend
    self.deactivate = deactivate
  }

  public var voiceDenial: AudioPlaybackError? {
    if isQuarantined {
      return .audioInUse(InlineAudioSessionError.quarantined.localizedDescription)
    }
    return switch current?.owner {
      case .recording: .audioInUse("Finish recording to play this message")
      case .draftPreview: .audioInUse("Pause the recording preview to play this message")
      case .video: .audioInUse("Pause the video to play this message")
      case .call: .audioInUse("Finish the call to play this message")
      case .voice, nil: nil
    }
  }

  public func acquire(_ owner: Owner) throws -> Token {
    guard !isQuarantined else { throw InlineAudioSessionError.quarantined }
    if owner == .voice, let current, current.owner == .voice {
      return current
    }
    if owner == .voice, let denial = voiceDenial {
      throw denial
    }
    if let current, current.owner != .voice {
      throw AudioPlaybackError.audioInUse("Other Inline audio is playing")
    }
    // A non-voice client fences pending requests even while no engine is playing.
    willAcquire?(owner)
    // A takeover callback can synchronously change ownership itself.
    if let current, current.owner != .voice {
      throw AudioPlaybackError.audioInUse("Other Inline audio is playing")
    }
    generation &+= 1
    let token = Token(owner: owner, generation: generation)
    current = token
    return token
  }

  public func owns(_ token: Token) -> Bool {
    current == token
  }

  /// Revokes the logical lease immediately. Its native teardown is ordered before the next activation.
  @discardableResult
  public func release(_ token: Token) -> Task<Void, Error>? {
    // Grid's reservation survives logical withdrawal until provider/native idle
    // and the matching native teardown both succeed.
    guard token != gridToken else { return nil }
    guard owns(token) else { return nil }
    current = nil
    deactivate()
    guard let backend else { return nil }
    return enqueue { try await backend.release(token: token) }
  }

  public func invalidate() {
    if gridToken != nil {
      quarantineAfterMediaServicesReset()
      return
    }
    generation &+= 1
    current = nil
    if let backend {
      _ = enqueue { await backend.invalidate() }
    }
  }

  func activate(_ token: Token, configuration: Configuration) async throws {
    guard token != gridToken else { throw InlineAudioSessionError.retirementPending }
    guard owns(token) else { throw CancellationError() }
    guard let backend else { return }
    let transition = enqueue { [weak self] in
      guard self?.owns(token) == true else { throw CancellationError() }
      try await backend.activate(token: token, configuration: configuration)
    }
    do {
      try await transition.value
      guard owns(token), !Task.isCancelled else { throw CancellationError() }
    } catch {
      release(token)
      throw error
    }
  }

  /// Read-only preflight; actual token acquisition repeats it after the claim.
  public func validateGridAdmission() throws {
    try validateGridAdmission(reusingReservation: false)
  }

  private func validateGridAdmission(reusingReservation: Bool) throws {
    guard !isQuarantined, !gridRestartRequired else { throw InlineAudioSessionError.quarantined }
    guard !gridRetiring, gridToken == nil || gridDemandActive || reusingReservation else {
      throw InlineAudioSessionError.retirementPending
    }
    switch current?.owner {
      case .recording: throw InlineAudioSessionError.recordingOwnsAudio
      case .draftPreview: throw AudioPlaybackError.audioInUse("Pause the recording preview before joining Grid.")
      case .video: throw AudioPlaybackError.audioInUse("Pause the video before joining Grid.")
      case .call where current != gridToken: throw AudioPlaybackError.audioInUse("Other Inline audio is playing")
      default: break
    }
  }

  public func setGridDemandActive(_ active: Bool, epoch: UInt64) async throws {
    guard epoch >= gridRequestedEpoch else { return }
    gridRequestedEpoch = epoch
    if let retirement = gridRetirementTask {
      // Once native release has been committed, wait for its token cleanup as
      // well. A successor cannot reuse a session that is being deactivated.
      await retirement.value
      guard epoch == gridRequestedEpoch else { return }
      try Task.checkCancellation()
    }
    guard epoch >= gridEpoch else { return }
    if active {
      let reusesReservation = epoch > gridEpoch && gridToken.map(owns) == true
      // A replacement room inherits the still-owned reservation while old
      // provider work retires; its stale receipts must not release the new room.
      try validateGridAdmission(reusingReservation: reusesReservation)
      if gridToken == nil {
        gridToken = try acquire(.call)
      }
    }
    if epoch != gridEpoch || active != gridDemandActive {
      gridMediaQuiescent = false
      gridDirectionsIdle = false
    }
    gridEpoch = epoch
    gridDemandActive = active
    guard active else {
      await finishGridRetirementIfReady()
      return
    }
    try await performGridTransition(epoch: epoch) { [weak self] token in
      guard let self, !gridNativeActive else { return }
      try await activateGridNative(token, epoch: epoch)
    }
  }

  public func gridMediaDidQuiesce(epoch: UInt64) async {
    guard epoch == gridEpoch, !gridDemandActive else { return }
    gridMediaQuiescent = true
    await finishGridRetirementIfReady()
  }

  public func observeGridDirections(
    recording: Bool, playing: Bool, nativeOperationsQuiescent: Bool, epoch: UInt64
  ) async {
    guard epoch == gridEpoch else { return }
    gridDirectionsIdle = nativeOperationsQuiescent && !recording && !playing
    refreshGridRoute()
    await finishGridRetirementIfReady()
  }

  /// Driver keeps ADM input/output closed across this receive-only recovery.
  public func resumeGridSession(epoch: UInt64) async throws {
    try await performGridTransition(epoch: epoch) { [weak self] token in
      guard let self else { throw CancellationError() }
      try await activateGridNative(token, epoch: epoch)
    }
  }

  private func activateGridNative(_ token: Token, epoch: UInt64) async throws {
    do {
      try await backend?.activate(token: token, configuration: .gridVoice)
      guard gridToken == token, owns(token), gridEpoch == epoch, gridDemandActive,
            !isQuarantined else { throw CancellationError() }
      if let backend {
        try await backend.setSpeakerPreferred(isSpeakerPreferred, token: token)
      }
    } catch {
      // Readiness includes the requested route. Only an entered native failure
      // can change it; rejected stale recovery never reaches this operation.
      if gridToken == token, owns(token) {
        gridNativeActive = false
      }
      throw error
    }
    if gridToken == token, owns(token) {
      gridNativeActive = true
    }
  }

  public func quarantineAfterMediaServicesReset() {
    gridRestartRequired = true
    // The persistent Grid observer must not change standalone reset behavior.
    if gridToken != nil {
      isQuarantined = true
    }
  }

  public func setSpeakerPreferred(_ preferred: Bool) async throws {
    let epoch = gridEpoch
    try await performGridTransition(epoch: epoch) { [weak self] token in
      guard let self, gridNativeActive else { throw InlineAudioSessionError.routeUnavailable }
      try await backend?.setSpeakerPreferred(preferred, token: token)
    }
    isSpeakerPreferred = preferred
    refreshGridRoute()
  }

  private func performGridTransition(
    epoch: UInt64, _ operation: @escaping @MainActor (Token) async throws -> Void
  ) async throws {
    guard let token = gridToken, owns(token), gridDemandActive, epoch == gridEpoch, !gridRetiring,
          !isQuarantined else { throw InlineAudioSessionError.retirementPending }
    gridTransitions += 1
    let transition = enqueue { [weak self] in
      guard let self, owns(token), gridToken == token, epoch == gridEpoch,
            gridDemandActive, !gridRetiring, !isQuarantined else { throw CancellationError() }
      try await operation(token)
    }
    let result: Result<Void, Error>
    do { try await transition.value
      result = .success(())
    } catch { result = .failure(error) }
    gridTransitions -= 1
    await finishGridRetirementIfReady()
    try result.get()
    guard gridToken == token, owns(token), epoch == gridEpoch, gridDemandActive,
          !isQuarantined, !Task.isCancelled else { throw CancellationError() }
    refreshGridRoute()
  }

  private func finishGridRetirementIfReady() async {
    guard let token = gridToken, owns(token), !gridDemandActive, gridMediaQuiescent,
          gridDirectionsIdle, gridTransitions == 0, !gridRetiring, !isQuarantined else { return }
    gridRetiring = true
    let epoch = gridEpoch
    let retirement = Task<Void, Never> { [weak self] in
      await self?.retireGridToken(token, epoch: epoch)
    }
    gridRetirementTask = retirement
    await retirement.value
  }

  private func retireGridToken(_ token: Token, epoch: UInt64) async {
    defer { gridRetirementTask = nil }
    let transition = enqueue { [weak self] in
      guard let self, gridToken == token, owns(token), gridEpoch == epoch,
            !gridDemandActive, gridMediaQuiescent, gridDirectionsIdle else { throw CancellationError() }
      try await backend?.release(token: token)
    }
    do {
      try await transition.value
      guard gridToken == token, owns(token) else { return }
      current = nil
      gridToken = nil
      gridNativeActive = false
      gridRetiring = false
      deactivate()
      refreshGridRoute()
    } catch {
      isQuarantined = true
      gridRetiring = false
    }
  }

  private func refreshGridRoute() {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    currentRouteName = session.currentRoute.outputs.first?.portName ?? "Audio"
    isSpeakerOutputActive = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    supportsReceiverRouting = isGridActive && session.category == .playAndRecord
    #endif
  }

  /// Only this chain may enter the native backend. Actor reentrancy alone does not order async I/O.
  private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
    let previous = transitionTail
    let transition = Task {
      await previous?.value
      try await operation()
    }
    transitionTail = Task { _ = try? await transition.value }
    return transition
  }

  #if os(iOS)
  public func activate(
    _ token: Token,
    category: AVAudioSession.Category,
    mode: AVAudioSession.Mode,
    options: AVAudioSession.CategoryOptions = []
  ) async throws {
    try await activate(token, configuration: Configuration(
      category: category.rawValue, mode: mode.rawValue, options: options.rawValue
    ))
  }
  #endif
}

/// A controlled async boundary for testing the same production transition chain without hardware.
protocol InlineAudioSessionBackend: Sendable {
  func activate(token: InlineAudioSession.Token, configuration: InlineAudioSession.Configuration) async throws
  func release(token: InlineAudioSession.Token) async throws
  func invalidate() async
  func setSpeakerPreferred(_ preferred: Bool, token: InlineAudioSession.Token) async throws
}

extension InlineAudioSessionBackend {
  func setSpeakerPreferred(_: Bool, token _: InlineAudioSession.Token) async throws {}
}

public enum InlineAudioSessionError: LocalizedError {
  case gridOwnsAudio, recordingOwnsAudio, quarantined, retirementPending, routeUnavailable

  public var errorDescription: String? {
    switch self {
      case .gridOwnsAudio: "Leave Grid to record a voice message."
      case .recordingOwnsAudio: "Finish recording your voice message before joining Grid."
      case .quarantined: "Audio needs to restart. Quit and reopen Inline before starting audio again."
      case .retirementPending: "Audio is still stopping. Try again shortly."
      case .routeUnavailable: "Audio output is unavailable. Resume Grid audio and try again."
    }
  }
}

#if os(iOS)
/// Native session configuration runs off MainActor. The owning session's FIFO prevents overlapping calls.
private actor NativeAudioSessionBackend: InlineAudioSessionBackend {
  private struct Snapshot {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let preferredIOBufferDuration: TimeInterval?
  }

  private var token: InlineAudioSession.Token?
  private var snapshot: Snapshot?

  func activate(token: InlineAudioSession.Token, configuration: InlineAudioSession.Configuration) async throws {
    // A failed release keeps its snapshot. Retry it before capturing or configuring a successor.
    let recoveringCall = self.token == token && token.owner == .call
    if !recoveringCall, let previous = self.token {
      try await release(token: previous)
    }
    let session = AVAudioSession.sharedInstance()
    if !recoveringCall {
      snapshot = Snapshot(
        category: session.category,
        mode: session.mode,
        options: session.categoryOptions,
        preferredIOBufferDuration: configuration.preferredIOBufferDuration == nil
          ? nil : session.preferredIOBufferDuration
      )
    }
    self.token = token
    do {
      try session.setCategory(
        AVAudioSession.Category(rawValue: configuration.category),
        mode: AVAudioSession.Mode(rawValue: configuration.mode),
        options: AVAudioSession.CategoryOptions(rawValue: configuration.options)
      )
      if let duration = configuration.preferredIOBufferDuration {
        try session.setPreferredIOBufferDuration(duration)
      }
      if #available(iOS 27.0, *) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          session.activate(options: []) { activated, error in
            if let error {
              continuation.resume(throwing: error)
            } else if activated {
              continuation.resume()
            } else {
              continuation.resume(throwing: AudioPlaybackError.playbackUnavailable)
            }
          }
        }
      } else {
        try session.setActive(true)
      }
      if configuration.usesAutomaticInput {
        try session.setPreferredInput(nil)
      }
    } catch {
      // Preserve cleanup state if teardown fails; a later activation retries it in this same lane.
      try? await release(token: token)
      throw error
    }
  }

  func release(token: InlineAudioSession.Token) async throws {
    guard self.token == token else { return }
    let session = AVAudioSession.sharedInstance()
    if #available(iOS 27.0, *) {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        session.deactivate(options: [.notifyOthersOnDeactivation]) { deactivated, error in
          if let error {
            continuation.resume(throwing: error)
          } else if deactivated {
            continuation.resume()
          } else {
            continuation.resume(throwing: AudioPlaybackError.playbackUnavailable)
          }
        }
      }
    } else {
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    if let snapshot {
      try session.setCategory(snapshot.category, mode: snapshot.mode, options: snapshot.options)
      if let duration = snapshot.preferredIOBufferDuration {
        try session.setPreferredIOBufferDuration(duration)
      }
    }
    snapshot = nil
    self.token = nil
  }

  func setSpeakerPreferred(_ preferred: Bool, token: InlineAudioSession.Token) async throws {
    guard self.token == token, token.owner == .call else { throw CancellationError() }
    try AVAudioSession.sharedInstance().overrideOutputAudioPort(preferred ? .speaker : .none)
  }

  func invalidate() async {
    // A reset invalidates restoration, but an in-flight activation may have just completed.
    // Retire that native lease before allowing any successor to snapshot/configure the session.
    snapshot = nil
    if let token {
      try? await release(token: token)
    }
  }
}
#endif
