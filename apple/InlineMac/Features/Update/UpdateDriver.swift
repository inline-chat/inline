#if SPARKLE
import Foundation
import Logger
import Sparkle

final class UpdateDriver: NSObject, SPUUserDriver {
  private let viewModel: UpdateViewModel
  private let presenter: UpdatePresenting
  private var downloadExpectedLength: Int64?
  private var downloadReceivedLength: Int64 = 0
  private var pendingActivation = false
  var retryCheck: (() -> Void)?
  private let log = Log.scoped("UpdateDriver")

  init(viewModel: UpdateViewModel, presenter: UpdatePresenting) {
    self.viewModel = viewModel
    self.presenter = presenter
    super.init()
  }

  private func setState(_ state: UpdateState) {
    let wasIdle = viewModel.state.isIdle
    viewModel.state = state
    if state.isIdle {
      presenter.closeIfNeeded()
    } else if wasIdle {
      presenter.show(activate: pendingActivation)
      pendingActivation = false
    }
  }

  func show(_ request: SPUUpdatePermissionRequest,
            reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
    _ = request
    setState(.permission(.init(
      message: "Inline would like to check for updates automatically.",
      allow: {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        self.setState(.idle)
      },
      deny: {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        self.setState(.idle)
      }
    )))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    pendingActivation = true
    setState(.checking(.init(cancel: {
      cancellation()
      self.setState(.idle)
    })))
  }

  func showUpdateFound(with appcastItem: SUAppcastItem,
                       state _: SPUUserUpdateState,
                       reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    log.info("Update found: \(appcastItem.displayVersionString) (\(appcastItem.versionString))")
    setState(.updateAvailable(.init(
      version: appcastItem.displayVersionString,
      build: appcastItem.versionString,
      contentLength: appcastItem.contentLength > 0 ? Int64(appcastItem.contentLength) : nil,
      install: { reply(.install) },
      later: {
        reply(.dismiss)
        self.setState(.idle)
      }
    )))
  }

  func showUpdateReleaseNotes(with _: SPUDownloadData) {
    // Inline does not use Sparkle's release notes presentation.
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_: any Error) {
    // No-op: release notes are not presented.
  }

  func showUpdateNotFoundWithError(_: any Error, acknowledgement: @escaping () -> Void) {
    log.info("No update available")
    setState(.notFound(.init(acknowledgement: {
      acknowledgement()
      self.setState(.idle)
    })))
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    let nsError = error as NSError
    log.error("Sparkle updater error (domain: \(nsError.domain) code: \(nsError.code))", error: error)
    if !nsError.userInfo.isEmpty {
      log.info("Sparkle error details: \(nsError.userInfo)")
    }
    setState(.error(.init(
      message: error.localizedDescription,
      retry: {
        acknowledgement()
        self.setState(.idle)
        self.retryCheck?()
      },
      dismiss: {
        acknowledgement()
        self.setState(.idle)
      }
    )))
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    log.info("Update download started")
    downloadExpectedLength = nil
    downloadReceivedLength = 0
    setState(.downloading(.init(
      cancel: {
        cancellation()
        self.setState(.idle)
      },
      expectedLength: nil,
      receivedLength: 0
    )))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    downloadExpectedLength = Int64(expectedContentLength)
    setState(.downloading(.init(
      cancel: cancelFromState(),
      expectedLength: downloadExpectedLength,
      receivedLength: downloadReceivedLength
    )))
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    downloadReceivedLength += Int64(length)
    setState(.downloading(.init(
      cancel: cancelFromState(),
      expectedLength: downloadExpectedLength,
      receivedLength: downloadReceivedLength
    )))
  }

  func showDownloadDidStartExtractingUpdate() {
    setState(.extracting(.init(progress: 0)))
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    setState(.extracting(.init(progress: progress)))
  }

  func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    log.info("Update ready to install")
    setState(.readyToInstall(.init(
      install: { reply(.install) },
      later: {
        reply(.dismiss)
        self.setState(.idle)
      }
    )))
  }

  func showInstallingUpdate(withApplicationTerminated _: Bool, retryTerminatingApplication: @escaping () -> Void) {
    setState(.installing(.init(
      retryTerminatingApplication: retryTerminatingApplication,
      dismiss: { self.setState(.idle) }
    )))
  }

  func showUpdateInstalledAndRelaunched(_: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    setState(.idle)
  }

  func showUpdateInFocus() {
    presenter.show(activate: true)
  }

  func dismissUpdateInstallation() {
    setState(.idle)
  }

  private func cancelFromState() -> () -> Void {
    if case let .downloading(state) = viewModel.state {
      return state.cancel
    }
    return {}
  }
}
#endif
