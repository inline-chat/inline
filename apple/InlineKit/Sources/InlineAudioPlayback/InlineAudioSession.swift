import Foundation
#if os(iOS)
import AVFAudio
#endif

/// A generation fence for the few Inline features that share the process audio session.
/// It does not own players or decide when they should resume.
@MainActor
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
  public var willAcquire: ((Owner) -> Void)?
  private var generation: UInt64 = 0
  private let deactivate: () -> Void
  private let backend: (any InlineAudioSessionBackend)?
  private var transitionTail: Task<Void, Never>?

  struct Configuration: Sendable {
    let category: String
    let mode: String
    let options: UInt

    static let voicePlayback = Configuration(
      category: "AVAudioSessionCategoryPlayback", mode: "AVAudioSessionModeSpokenAudio", options: 0
    )
  }

  var requiresNativeTransition: Bool { backend != nil }

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
    switch current?.owner {
    case .recording: .audioInUse("Finish recording to play this message")
    case .draftPreview: .audioInUse("Pause the recording preview to play this message")
    case .video: .audioInUse("Pause the video to play this message")
    case .call: .audioInUse("Finish the call to play this message")
    case .voice, nil: nil
    }
  }

  public func acquire(_ owner: Owner) throws -> Token {
    if owner == .voice, let current, current.owner == .voice { return current }
    if owner == .voice, let denial = voiceDenial { throw denial }
    if let current, current.owner != .voice {
      throw AudioPlaybackError.audioInUse("Other Inline audio is playing")
    }
    // A non-voice client fences pending requests even while no engine is playing.
    willAcquire?(owner)
    generation &+= 1
    let token = Token(owner: owner, generation: generation)
    current = token
    return token
  }

  public func owns(_ token: Token) -> Bool { current == token }

  /// Revokes the logical lease immediately. Its native teardown is ordered before the next activation.
  @discardableResult
  public func release(_ token: Token) -> Task<Void, Error>? {
    guard owns(token) else { return nil }
    current = nil
    deactivate()
    guard let backend else { return nil }
    return enqueue { try await backend.release(token: token) }
  }

  public func invalidate() {
    generation &+= 1
    current = nil
    if let backend {
      _ = enqueue { await backend.invalidate() }
    }
  }

  func activate(_ token: Token, configuration: Configuration) async throws {
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
}

#if os(iOS)
/// Native session configuration runs off MainActor. The owning session's FIFO prevents overlapping calls.
private actor NativeAudioSessionBackend: InlineAudioSessionBackend {
  private struct Snapshot {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
  }
  private var token: InlineAudioSession.Token?
  private var snapshot: Snapshot?

  func activate(token: InlineAudioSession.Token, configuration: InlineAudioSession.Configuration) async throws {
    // A failed release keeps its snapshot. Retry it before capturing or configuring a successor.
    if let previous = self.token { try await release(token: previous) }
    let session = AVAudioSession.sharedInstance()
    snapshot = Snapshot(category: session.category, mode: session.mode, options: session.categoryOptions)
    self.token = token
    do {
      try session.setCategory(AVAudioSession.Category(rawValue: configuration.category),
                              mode: AVAudioSession.Mode(rawValue: configuration.mode),
                              options: AVAudioSession.CategoryOptions(rawValue: configuration.options))
      if #available(iOS 27.0, *) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          session.activate(options: []) { activated, error in
            if let error { continuation.resume(throwing: error) }
            else if activated { continuation.resume() }
            else { continuation.resume(throwing: AudioPlaybackError.playbackUnavailable) }
          }
        }
      } else {
        try session.setActive(true)
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
          if let error { continuation.resume(throwing: error) }
          else if deactivated { continuation.resume() }
          else { continuation.resume(throwing: AudioPlaybackError.playbackUnavailable) }
        }
      }
    } else {
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    if let snapshot {
      try session.setCategory(snapshot.category, mode: snapshot.mode, options: snapshot.options)
    }
    self.snapshot = nil
    self.token = nil
  }

  func invalidate() async {
    // A reset invalidates restoration, but an in-flight activation may have just completed.
    // Retire that native lease before allowing any successor to snapshot/configure the session.
    snapshot = nil
    if let token { try? await release(token: token) }
  }
}
#endif
