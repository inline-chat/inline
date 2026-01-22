#if SPARKLE
import AppKit
import Logger
import Sparkle

final class UpdateController: NSObject {
  private let updater: SPUUpdater
  private let userDriver: UpdateDriver
  private let updateDelegate: UpdateDelegate
  private var didStart = false
  private let log = Log.scoped("UpdateController")

  override init() {
    let viewModel = UpdateViewModel()
    let presenter = UpdateWindowController(viewModel: viewModel)
    userDriver = UpdateDriver(viewModel: viewModel, presenter: presenter)
    updateDelegate = UpdateDelegate()
    updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: userDriver,
      delegate: updateDelegate
    )
    userDriver.retryCheck = { [weak updater] in
      updater?.checkForUpdates()
    }
    super.init()
    log.info("Initialized Sparkle updater")
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
    updater.checkForUpdates()
  }
}
#endif
