#if SPARKLE
import AppKit
import Sparkle

@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
  weak var controller: UpdateController?

  func show(_: SPUUpdatePermissionRequest,
            reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
    controller?.didRequestUpdatePermission(reply: reply)
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    controller?.didBeginUserInitiatedCheck(cancellation: cancellation)
  }

  func showUpdateFound(with appcastItem: SUAppcastItem,
                       state: SPUUserUpdateState,
                       reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    controller?.didFindUpdate(appcastItem, state: state, reply: reply)
  }

  func showUpdateReleaseNotes(with _: SPUDownloadData) {
    // Inline does not use Sparkle's release notes presentation.
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_: any Error) {
    // No-op: release notes are not presented.
  }

  func showUpdateNotFoundWithError(_: any Error, acknowledgement: @escaping () -> Void) {
    controller?.didNotFindUpdate(acknowledgement: acknowledgement)
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    controller?.didReceiveUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    controller?.didStartDownload(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    controller?.didReceiveDownloadLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    controller?.didReceiveDownloadData(length)
  }

  func showDownloadDidStartExtractingUpdate() {
    controller?.didStartExtracting()
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    controller?.didReceiveExtractionProgress(progress)
  }

  func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    controller?.didBecomeReadyFromUserFlow(reply: reply)
  }

  func showInstallingUpdate(withApplicationTerminated _: Bool, retryTerminatingApplication: @escaping () -> Void) {
    controller?.didBeginInstalling(retryTermination: retryTerminatingApplication)
  }

  func showUpdateInstalledAndRelaunched(_: Bool, acknowledgement: @escaping () -> Void) {
    controller?.didFinishInstallation(acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() {
    controller?.showCurrentUpdate(activate: true)
  }

  func dismissUpdateInstallation() {
    controller?.didDismissInstallation()
  }
}
#endif
