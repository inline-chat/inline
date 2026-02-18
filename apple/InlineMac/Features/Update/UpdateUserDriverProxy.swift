#if SPARKLE
import Foundation
import Sparkle

final class UpdateUserDriverProxy: NSObject, SPUUserDriver {
  private let baseDriver: SPUStandardUserDriver
  private let installState: UpdateInstallState
  private var latestUpdateVersion: String?
  private var latestUpdateBuild: String?
  private var downloadExpectedLength: Int64?
  private var downloadReceivedLength: Int64 = 0

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
    Task { @MainActor in
      self.installState.setChecking()
    }
    baseDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
  }

  func showUpdateFound(with appcastItem: SUAppcastItem,
                       state: SPUUserUpdateState,
                       reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    latestUpdateVersion = appcastItem.displayVersionString
    latestUpdateBuild = appcastItem.versionString
    Task { @MainActor in
      self.installState.setUpdateAvailable(
        version: self.latestUpdateVersion ?? "Unknown",
        build: self.latestUpdateBuild
      )
    }
    baseDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    baseDriver.showUpdateReleaseNotes(with: downloadData)
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    baseDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
  }

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    Task { @MainActor in
      self.installState.setUpToDate()
    }
    baseDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    Task { @MainActor in
      self.installState.setError(message: error.localizedDescription)
    }
    baseDriver.showUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    downloadExpectedLength = nil
    downloadReceivedLength = 0
    Task { @MainActor in
      self.installState.setDownloading(receivedBytes: 0, expectedBytes: nil)
    }
    baseDriver.showDownloadInitiated(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    downloadExpectedLength = Int64(expectedContentLength)
    Task { @MainActor in
      self.installState.setDownloading(
        receivedBytes: self.downloadReceivedLength,
        expectedBytes: self.downloadExpectedLength
      )
    }
    baseDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    downloadReceivedLength += Int64(length)
    Task { @MainActor in
      self.installState.setDownloading(
        receivedBytes: self.downloadReceivedLength,
        expectedBytes: self.downloadExpectedLength
      )
    }
    baseDriver.showDownloadDidReceiveData(ofLength: length)
  }

  func showDownloadDidStartExtractingUpdate() {
    Task { @MainActor in
      self.installState.setExtracting()
    }
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
        if choice == .install {
          self.installState.setInstalling()
        } else {
          self.installState.resetToIdle()
        }
      }
      reply(choice)
    }

    Task { @MainActor in
      self.installState.setReady(version: self.latestUpdateVersion, build: self.latestUpdateBuild, install: {
        wrappedReply(.install)
      })
    }

    baseDriver.showReady(toInstallAndRelaunch: wrappedReply)
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    Task { @MainActor in
      self.installState.setInstalling()
    }
    baseDriver.showInstallingUpdate(
      withApplicationTerminated: applicationTerminated,
      retryTerminatingApplication: retryTerminatingApplication
    )
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    Task { @MainActor in
      self.installState.resetToIdle()
    }
    baseDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() {
    baseDriver.showUpdateInFocus()
  }

  func dismissUpdateInstallation() {
    Task { @MainActor in
      self.installState.resetToIdle()
    }
    baseDriver.dismissUpdateInstallation()
  }
}
#endif
