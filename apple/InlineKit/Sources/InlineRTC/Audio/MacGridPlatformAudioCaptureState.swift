import Foundation

#if os(macOS)
struct MacGridPlatformAudioCaptureState: Equatable, Sendable {
  private(set) var appliedInputTarget: AudioInputRouteTarget?
  private(set) var isPrepared = false

  mutating func inputSelected(_ target: AudioInputRouteTarget) {
    appliedInputTarget = target
  }

  mutating func inputSelectionLost() {
    appliedInputTarget = nil
  }

  mutating func recordingStarted() {
    isPrepared = true
  }

  mutating func recordingStopped() {
    isPrepared = false
  }

  func recoveryTarget(preserving target: AudioInputRouteTarget?) -> AudioInputRouteTarget {
    target ?? appliedInputTarget ?? .automatic
  }
}
#endif
