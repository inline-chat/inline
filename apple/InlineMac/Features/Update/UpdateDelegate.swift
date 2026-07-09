#if SPARKLE
import AppKit
import Logger
import Sparkle

final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
  @MainActor weak var controller: UpdateController?
  private let log = Log.scoped("UpdateDelegate")

  func feedURLString(for _: SPUUpdater) -> String? {
    guard let url = controller?.feedURLString else { return nil }
    log.info("Using appcast: \(url)")
    return url
  }

  func updater(_: SPUUpdater, mayPerform _: SPUUpdateCheck) throws {
    controller?.didBeginUpdateCheck()
  }

  func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    controller?.didFindBackgroundUpdate(item)
  }

  func updater(_: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with _: NSMutableURLRequest) {
    controller?.willDownloadBackgroundUpdate(item)
  }

  func updater(_: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    controller?.didDownloadBackgroundUpdate(item)
  }

  func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error: any Error) {
    controller?.didFailBackgroundDownload(error)
  }

  func updater(_: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
    controller?.willExtractBackgroundUpdate(item)
  }

  func updater(
    _: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock install: @escaping () -> Void
  ) -> Bool {
    controller?.didPrepareBackgroundUpdate(item, install: install)
    return true
  }

  func updater(
    _: SPUUpdater,
    didFinishUpdateCycleFor _: SPUUpdateCheck,
    error: (any Error)?
  ) {
    controller?.didFinishUpdateCycle(error: error)
  }

  func updater(_: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
    controller?.willScheduleNextCheck(after: delay)
  }

  func updaterWillNotScheduleUpdateCheck(_: SPUUpdater) {
    controller?.willNotScheduleChecks()
  }

  func updaterWillRelaunchApplication(_: SPUUpdater) {
    controller?.willRelaunchApplication()
  }
}
#endif
