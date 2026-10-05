import Foundation

public struct AudioPlaybackCommandIdentity: Equatable, Sendable {
  public let item: AudioPlaybackItem
  public let revision: UInt64
}

/// Remote callbacks arrive off actor. Capture the publication they address before hopping to playback.
final class AudioPlaybackCommandAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var identity: AudioPlaybackCommandIdentity?

  func publish(_ identity: AudioPlaybackCommandIdentity?) {
    lock.lock()
    self.identity = identity
    lock.unlock()
  }

  func receive<Result>(
    unavailable: Result,
    execute: (AudioPlaybackCommandIdentity) -> Result
  ) -> Result {
    lock.lock()
    let received = identity
    lock.unlock()
    guard let received else { return unavailable }
    return execute(received)
  }
}
