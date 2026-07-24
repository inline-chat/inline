import Foundation

#if os(macOS)
struct MacGridPlatformAudioCaptureState: Equatable, Sendable {
  private(set) var appliedInputTarget: AudioInputRouteTarget?
  private(set) var appliedInputDeviceUID: String?
  private(set) var isPrepared = false

  mutating func inputSelected(
    _ target: AudioInputRouteTarget,
    deviceUID: String? = nil
  ) {
    appliedInputTarget = target
    appliedInputDeviceUID = deviceUID
  }

  mutating func inputSelectionLost() {
    appliedInputTarget = nil
    appliedInputDeviceUID = nil
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

  func canCommitUnchangedAutomaticRoute(
    requesting target: AudioInputRouteTarget,
    selectionWasAttempted: Bool,
    recordingRestored: Bool
  ) -> Bool {
    !selectionWasAttempted
      && recordingRestored
      && target == .automatic
      && appliedInputTarget == .automatic
  }
}
#endif
