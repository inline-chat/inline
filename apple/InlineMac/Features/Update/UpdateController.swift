#if SPARKLE
import AppKit
import Combine
import Logger
import Sparkle

final class UpdateController: NSObject {
  private let updater: SPUUpdater
  private let installState: UpdateInstallState
  private let updateDelegate: UpdateDelegate
  private let userDriver: UpdateUserDriverProxy
  private var settingsCancellable: AnyCancellable?
  private var didStart = false
  private let log = Log.scoped("UpdateController")

  init(installState: UpdateInstallState) {
    self.installState = installState
    updateDelegate = UpdateDelegate()
    let standardDriver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    userDriver = UpdateUserDriverProxy(installState: installState, baseDriver: standardDriver)
    updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: userDriver,
      delegate: updateDelegate
    )
    super.init()
    settingsCancellable = AppSettings.shared.$autoUpdateMode
      .receive(on: DispatchQueue.main)
      .sink { [weak self] mode in
        self?.applyAutoUpdateMode(mode)
      }
    applyAutoUpdateMode(AppSettings.shared.autoUpdateMode)
    log.info("Initialized Sparkle updater (standard UI)")
  }

  func startIfNeeded() {
    guard !didStart else { return }
    do {
      log.info("Starting Sparkle updater")
      try updater.start()
      didStart = true
      log.info("Sparkle updater started")
    } catch {
      didStart = false
      log.error("Failed to start Sparkle updater", error: error)
    }
  }

  @objc func checkForUpdates() {
    log.info("User initiated update check (started: \(didStart))")
    startIfNeeded()
    installState.setChecking()
    updater.checkForUpdates()
  }

  private func applyAutoUpdateMode(_ mode: AutoUpdateMode) {
    switch mode {
    case .off:
      updater.automaticallyChecksForUpdates = false
      updater.automaticallyDownloadsUpdates = false
    case .check:
      updater.automaticallyChecksForUpdates = true
      updater.automaticallyDownloadsUpdates = false
    case .download:
      updater.automaticallyChecksForUpdates = true
      updater.automaticallyDownloadsUpdates = true
    }
    log.info("Auto-update mode set to \(mode.rawValue)")
  }
}
#endif
