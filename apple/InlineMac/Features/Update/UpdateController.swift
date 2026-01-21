#if SPARKLE
import AppKit
import Sparkle

@MainActor
final class UpdateController: NSObject {
  private let updater: SPUUpdater
  private let userDriver: UpdateDriver
  private let updateDelegate: UpdateDelegate
  private var didStart = false

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
  }

  func startIfNeeded() {
    guard !didStart else { return }
    do {
      try updater.start()
      didStart = true
    } catch {
      didStart = false
    }
  }

  @objc func checkForUpdates() {
    startIfNeeded()
    updater.checkForUpdates()
  }
}
#endif
