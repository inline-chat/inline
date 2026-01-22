#if SPARKLE
import AppKit
import Logger
import Sparkle

final class UpdateController: NSObject {
  private let updater: SPUUpdater
  private let updateDelegate: UpdateDelegate
  private let userDriver: SPUStandardUserDriver
  private var didStart = false
  private let log = Log.scoped("UpdateController")

  override init() {
    updateDelegate = UpdateDelegate()
    userDriver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: userDriver,
      delegate: updateDelegate
    )
    super.init()
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
    updater.checkForUpdates()
  }
}
#endif
