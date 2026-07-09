#if SPARKLE
import AppKit
import Logger
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
  static let scheduledCheckInterval: TimeInterval = 60 * 60
  private static let modeDefaultsKey = "autoUpdateMode"
  private static let channelDefaultsKey = "autoUpdateChannel"

  private(set) var phase: SoftwareUpdatePhase = .idle
  private(set) var lastCheckDate: Date?
  private(set) var nextScheduledCheckDate: Date?
  private(set) var canCheckForUpdates = false

  var mode: AutoUpdateMode {
    didSet {
      guard mode != oldValue else { return }
      UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
      applyAutoUpdateMode()
    }
  }

  var channel: AutoUpdateChannel {
    didSet {
      guard channel != oldValue else { return }
      UserDefaults.standard.set(channel.rawValue, forKey: Self.channelDefaultsKey)
      guard didStart else { return }
      updater.resetUpdateCycle()
      log.info("Update channel set to \(channel.rawValue)")
    }
  }

#if DEBUG
  var debugForceReady = false {
    didSet {
      guard debugForceReady != oldValue else { return }
      if debugForceReady {
        let info = SoftwareUpdateInfo(
          version: "Debug Update",
          build: nil,
          contentLength: nil,
          informationURL: nil
        )
        latestUpdate = info
        phase = .readyToInstall(info)
      } else if installHandler == nil, updateChoiceReply == nil, case .readyToInstall = phase {
        resetToIdle()
      }
    }
  }
#endif

  @ObservationIgnored private let updater: SPUUpdater
  @ObservationIgnored private let updateDelegate: UpdateDelegate
  @ObservationIgnored private let userDriver: UpdateDriver
  @ObservationIgnored private lazy var presenter = UpdateWindowController(controller: self)
  @ObservationIgnored private var updateChoiceReply: (@Sendable (SPUUserUpdateChoice) -> Void)?
  @ObservationIgnored private var cancelHandler: (() -> Void)?
  @ObservationIgnored private var acknowledgementHandler: (() -> Void)?
  @ObservationIgnored private var installHandler: (() -> Void)?
  @ObservationIgnored private var retryTerminationHandler: (() -> Void)?
  @ObservationIgnored private var latestUpdate: SoftwareUpdateInfo?
  @ObservationIgnored private var manualCheckInProgress = false
  @ObservationIgnored private var retryAfterCurrentCycle = false
  @ObservationIgnored private var didStart = false
  private let log = Log.scoped("UpdateController")

  init() {
    mode = Self.loadMode()
    channel = Self.loadChannel()
    let updateDelegate = UpdateDelegate()
    let userDriver = UpdateDriver()
    self.updateDelegate = updateDelegate
    self.userDriver = userDriver
    updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: userDriver,
      delegate: updateDelegate
    )
    userDriver.controller = self
    updateDelegate.controller = self
    log.info("Initialized centralized Sparkle updater")
  }

  func start() {
    guard !didStart else { return }

    updater.updateCheckInterval = Self.scheduledCheckInterval
    applyAutoUpdateMode()

    do {
      log.info("Starting Sparkle updater")
      try updater.start()
      didStart = true
      canCheckForUpdates = updater.canCheckForUpdates
      lastCheckDate = updater.lastUpdateCheckDate
      log.info("Sparkle updater started with a \(Int(Self.scheduledCheckInterval))-second interval")

      if mode != .off {
        // Sparkle explicitly permits a background check immediately after start.
        // This also resumes a previously prepared update without waiting for the
        // normal one-hour schedule (or Sparkle's one-week impatient reminder).
        updater.checkForUpdatesInBackground()
      }
    } catch {
      didStart = false
      phase = .failed(message: error.localizedDescription)
      log.error("Failed to start Sparkle updater", error: error)
    }
  }

  func checkForUpdates() {
    start()
    guard didStart else {
      showCurrentUpdate(activate: true)
      return
    }

    guard updater.canCheckForUpdates else {
      showCurrentUpdate(activate: true)
      return
    }

    switch phase {
    case .updateAvailable, .readyToInstall, .downloading, .extracting, .installing:
      showCurrentUpdate(activate: true)
      return
    case .idle, .checking, .upToDate, .failed:
      break
    }

    clearTransientHandlers()
    manualCheckInProgress = true
    canCheckForUpdates = false
    phase = .checking
    presenter.show(activate: true)
    log.info("User initiated update check")
    updater.checkForUpdates()
  }

  func performPrimaryAction() {
    switch phase {
    case .updateAvailable:
      showCurrentUpdate(activate: true)
    case .readyToInstall:
      installAndRelaunch()
    case .checking, .downloading, .extracting, .installing:
      showCurrentUpdate(activate: true)
    case .idle, .upToDate, .failed:
      retryCheck()
    }
  }

  func beginUpdate() {
    if latestUpdate?.isInformational == true {
      openInformationPage()
      return
    }

    guard let reply = updateChoiceReply else { return }
    updateChoiceReply = nil
    cancelHandler = nil
    phase = .downloading(info: latestUpdate, receivedBytes: nil, expectedBytes: latestUpdate?.contentLength)
    reply(.install)
  }

  func remindLater() {
    guard let reply = updateChoiceReply else {
      presenter.closeIfNeeded()
      return
    }
    updateChoiceReply = nil
    reply(.dismiss)
    resetToIdle()
  }

  func skipVersion() {
    guard let reply = updateChoiceReply else { return }
    updateChoiceReply = nil
    reply(.skip)
    resetToIdle()
  }

  func cancel() {
    guard let handler = cancelHandler else {
      presenter.closeIfNeeded()
      return
    }
    cancelHandler = nil
    handler()
    resetToIdle()
  }

  func retryCheck() {
    retryAfterCurrentCycle = didStart && (acknowledgementHandler != nil || updater.sessionInProgress)
    acknowledgeIfNeeded()
    resetToIdle(closeWindow: false)
    if retryAfterCurrentCycle {
      scheduleDeferredRetryIfPossible()
    } else {
      checkForUpdates()
    }
  }

  func dismissStatus() {
    acknowledgeIfNeeded()
    resetToIdle()
  }

  func installAndRelaunch() {
    if let handler = installHandler {
      // Sparkle explicitly permits retrying this handler if application
      // termination is cancelled. Keep the handler and ready state alive until
      // the process actually exits.
      handler()
      return
    }

    if let reply = updateChoiceReply {
      updateChoiceReply = nil
      phase = .installing(latestUpdate)
      reply(.install)
      return
    }

#if DEBUG
    if debugForceReady {
      debugForceReady = false
    }
#endif
  }

  func retryTermination() {
    retryTerminationHandler?()
  }

  var canCancelCurrentOperation: Bool { cancelHandler != nil }

  var canRetryTermination: Bool { retryTerminationHandler != nil }

  func showCurrentUpdate(activate: Bool) {
    presenter.show(activate: activate)
  }

  var showsSidebarAction: Bool {
#if DEBUG
    if debugForceReady { return true }
#endif
    switch phase {
    case .updateAvailable, .readyToInstall:
      true
    default:
      false
    }
  }

  var sidebarActionTitle: String {
    if case .updateAvailable = phase {
      return "Update Available"
    }
    return "Restart to Update"
  }

  var allowsPrimaryAction: Bool {
    switch phase {
    case .idle, .upToDate, .failed:
      canCheckForUpdates || !didStart
    case .updateAvailable, .readyToInstall:
      true
    case .checking, .downloading, .extracting, .installing:
      false
    }
  }

  var feedURLString: String {
    switch channel {
    case .stable:
      "https://public-assets.inline.chat/mac/stable/appcast.xml"
    case .beta:
      "https://public-assets.inline.chat/mac/beta/appcast.xml"
    }
  }

  // MARK: - Sparkle user-driver callbacks

  func didRequestUpdatePermission(
    reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: mode != .off, sendSystemProfile: false))
  }

  func didBeginUserInitiatedCheck(cancellation: @escaping () -> Void) {
    manualCheckInProgress = true
    canCheckForUpdates = false
    cancelHandler = cancellation
    phase = .checking
    presenter.show(activate: true)
  }

  func didFindUpdate(
    _ item: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
  ) {
    let info = updateInfo(for: item)
    latestUpdate = info
    updateChoiceReply = reply
    cancelHandler = nil
    if state.stage == .installing {
      phase = .readyToInstall(info)
    } else {
      phase = .updateAvailable(info)
    }
    if state.userInitiated {
      presenter.show(activate: true)
    }
  }

  func didBeginUpdateCheck() {
    canCheckForUpdates = false
    nextScheduledCheckDate = nil
    switch phase {
    case .idle, .upToDate, .failed:
      phase = .checking
    case .checking, .updateAvailable, .downloading, .extracting, .readyToInstall, .installing:
      break
    }
  }

  func didNotFindUpdate(acknowledgement: @escaping () -> Void) {
    cancelHandler = nil
    acknowledgementHandler = acknowledgement
    phase = .upToDate
    if manualCheckInProgress {
      presenter.show(activate: true)
    }
    manualCheckInProgress = false
  }

  func didReceiveUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    cancelHandler = nil
    acknowledgementHandler = acknowledgement
    phase = .failed(message: error.localizedDescription)
    presenter.show(activate: true)
    manualCheckInProgress = false
    log.error("Sparkle updater error", error: error)
  }

  func didStartDownload(cancellation: @escaping () -> Void) {
    cancelHandler = cancellation
    phase = .downloading(info: latestUpdate, receivedBytes: 0, expectedBytes: latestUpdate?.contentLength)
  }

  func didReceiveDownloadLength(_ expectedBytes: UInt64) {
    phase = .downloading(
      info: latestUpdate,
      receivedBytes: receivedBytes,
      expectedBytes: Int64(expectedBytes)
    )
  }

  func didReceiveDownloadData(_ length: UInt64) {
    phase = .downloading(
      info: latestUpdate,
      receivedBytes: (receivedBytes ?? 0) + Int64(length),
      expectedBytes: expectedBytes
    )
  }

  func didStartExtracting() {
    cancelHandler = nil
    phase = .extracting(info: latestUpdate, progress: nil)
  }

  func didReceiveExtractionProgress(_ progress: Double) {
    phase = .extracting(info: latestUpdate, progress: progress)
  }

  func didBecomeReadyFromUserFlow(reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    // Reaching this callback means the user already chose to install. Continue
    // directly instead of asking a second time after the download finishes.
    phase = .installing(latestUpdate)
    reply(.install)
  }

  func didBeginInstalling(retryTermination: @escaping () -> Void) {
    cancelHandler = nil
    retryTerminationHandler = retryTermination
    phase = .installing(latestUpdate)
  }

  func didFinishInstallation(acknowledgement: @escaping () -> Void) {
    acknowledgement()
    resetToIdle()
  }

  func didDismissInstallation() {
    guard installHandler == nil else { return }
    resetToIdle()
  }

  // MARK: - Sparkle updater-delegate callbacks

  func didFindBackgroundUpdate(_ item: SUAppcastItem) {
    let info = updateInfo(for: item)
    latestUpdate = info
    if mode == .download, !manualCheckInProgress {
      phase = .downloading(info: info, receivedBytes: nil, expectedBytes: info.contentLength)
    } else {
      phase = .updateAvailable(info)
    }
  }

  func willDownloadBackgroundUpdate(_ item: SUAppcastItem) {
    latestUpdate = updateInfo(for: item)
    phase = .downloading(info: latestUpdate, receivedBytes: nil, expectedBytes: latestUpdate?.contentLength)
  }

  func didDownloadBackgroundUpdate(_ item: SUAppcastItem) {
    latestUpdate = updateInfo(for: item)
    phase = .extracting(info: latestUpdate, progress: nil)
  }

  func didFailBackgroundDownload(_ error: any Error) {
    phase = .failed(message: error.localizedDescription)
    log.error("Background update download failed", error: error)
  }

  func willExtractBackgroundUpdate(_ item: SUAppcastItem) {
    latestUpdate = updateInfo(for: item)
    phase = .extracting(info: latestUpdate, progress: nil)
  }

  func didPrepareBackgroundUpdate(
    _ item: SUAppcastItem,
    install: @escaping () -> Void
  ) {
    let info = updateInfo(for: item)
    latestUpdate = info
    installHandler = install
    cancelHandler = nil
    nextScheduledCheckDate = nil
    phase = .readyToInstall(info)
    log.info("Update \(info.version) is downloaded and ready to install")
  }

  func didFinishUpdateCycle(error: (any Error)?) {
    lastCheckDate = updater.lastUpdateCheckDate
    canCheckForUpdates = updater.canCheckForUpdates

    if case .checking = phase {
      if let error, !isExpectedCycleCompletion(error) {
        phase = .failed(message: error.localizedDescription)
        log.error("Update check failed", error: error)
      } else if manualCheckInProgress {
        phase = .upToDate
      } else {
        phase = .idle
      }
      manualCheckInProgress = false
    }

    scheduleDeferredRetryIfPossible()
  }

  func willScheduleNextCheck(after delay: TimeInterval) {
    nextScheduledCheckDate = Date().addingTimeInterval(delay)
    canCheckForUpdates = updater.canCheckForUpdates
  }

  func willNotScheduleChecks() {
    nextScheduledCheckDate = nil
    canCheckForUpdates = updater.canCheckForUpdates
  }

  func willRelaunchApplication() {
    NSApp.invalidateRestorableState()
    for window in NSApp.windows {
      window.invalidateRestorableState()
    }
  }

  private func applyAutoUpdateMode() {
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

  private static func loadMode() -> AutoUpdateMode {
    guard let value = UserDefaults.standard.string(forKey: modeDefaultsKey),
          let mode = AutoUpdateMode(rawValue: value) else {
      return .download
    }
    return mode
  }

  private static func loadChannel() -> AutoUpdateChannel {
    if let value = UserDefaults.standard.string(forKey: channelDefaultsKey),
       let channel = AutoUpdateChannel(rawValue: value) {
      return channel
    }

    guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
      return .stable
    }
    return feedURL.contains("/beta/") ? .beta : .stable
  }

  private func updateInfo(for item: SUAppcastItem) -> SoftwareUpdateInfo {
    SoftwareUpdateInfo(
      version: item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString,
      build: item.versionString,
      contentLength: item.contentLength > 0 ? Int64(item.contentLength) : nil,
      informationURL: item.isInformationOnlyUpdate ? item.infoURL : nil
    )
  }

  private func openInformationPage() {
    guard let url = latestUpdate?.informationURL else { return }
    NSWorkspace.shared.open(url)
    let reply = updateChoiceReply
    updateChoiceReply = nil
    reply?(.dismiss)
    resetToIdle()
  }

  private func isExpectedCycleCompletion(_ error: any Error) -> Bool {
    let code = (error as NSError).code
    // Sparkle's Objective-C SUError cases are not imported as Swift symbols.
    // These stable public codes are defined in Sparkle/SUErrors.h.
    return code == 1001 // SUNoUpdateError
      || code == 4007 // SUInstallationCanceledError
      || code == 4008 // SUInstallationAuthorizeLaterError
  }

  private var receivedBytes: Int64? {
    if case let .downloading(_, receivedBytes, _) = phase {
      return receivedBytes
    }
    return nil
  }

  private var expectedBytes: Int64? {
    if case let .downloading(_, _, expectedBytes) = phase {
      return expectedBytes
    }
    return nil
  }

  private func acknowledgeIfNeeded() {
    let handler = acknowledgementHandler
    acknowledgementHandler = nil
    handler?()
  }

  private func scheduleDeferredRetryIfPossible() {
    guard retryAfterCurrentCycle, updater.canCheckForUpdates else { return }
    retryAfterCurrentCycle = false
    Task { @MainActor [weak self] in
      self?.checkForUpdates()
    }
  }

  private func clearTransientHandlers() {
    acknowledgeIfNeeded()
    updateChoiceReply = nil
    cancelHandler = nil
    retryTerminationHandler = nil
  }

  private func resetToIdle(closeWindow: Bool = true) {
    clearTransientHandlers()
    manualCheckInProgress = false
    phase = .idle
    if closeWindow {
      presenter.closeIfNeeded()
    }
  }
}
#endif
