#if SPARKLE
import Foundation
import Sparkle

final class UpdateUserDriverProxy: NSObject, SPUUserDriver {
  private let baseDriver: SPUStandardUserDriver
  private let installState: UpdateInstallState

  init(installState: UpdateInstallState, baseDriver: SPUStandardUserDriver) {
    self.installState = installState
    self.baseDriver = baseDriver
    super.init()
  }

  func show(_ request: SPUUpdatePermissionRequest,
            reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
    baseDriver.show(request, reply: reply)
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    baseDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
  }

  func showUpdateFound(with appcastItem: SUAppcastItem,
                       state: SPUUserUpdateState,
                       reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    baseDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    baseDriver.showUpdateReleaseNotes(with: downloadData)
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    baseDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
  }

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    baseDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    baseDriver.showUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    baseDriver.showDownloadInitiated(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    baseDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    baseDriver.showDownloadDidReceiveData(ofLength: length)
  }

  func showDownloadDidStartExtractingUpdate() {
    baseDriver.showDownloadDidStartExtractingUpdate()
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    baseDriver.showExtractionReceivedProgress(progress)
  }

  func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    var didReply = false
    let wrappedReply: (SPUUserUpdateChoice) -> Void = { choice in
      guard !didReply else { return }
      didReply = true
      Task { @MainActor in
        self.installState.clear()
      }
      reply(choice)
    }

    Task { @MainActor in
      self.installState.setReady(install: {
        wrappedReply(.install)
      })
    }

    baseDriver.showReady(toInstallAndRelaunch: wrappedReply)
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    Task { @MainActor in
      self.installState.clear()
    }
    baseDriver.showInstallingUpdate(
      withApplicationTerminated: applicationTerminated,
      retryTerminatingApplication: retryTerminatingApplication
    )
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    Task { @MainActor in
      self.installState.clear()
    }
    baseDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() {
    baseDriver.showUpdateInFocus()
  }

  func dismissUpdateInstallation() {
    Task { @MainActor in
      self.installState.clear()
    }
    baseDriver.dismissUpdateInstallation()
  }
}
#endif
