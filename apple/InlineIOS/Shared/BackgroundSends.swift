import BackgroundTasks
import Combine
import Foundation
import InlineKit
import Logger
import UIKit

/// Keeps media sends going when the app leaves the screen, as Telegram's `SharedWakeupManager`
/// does:
/// - In the background, a background task holds the process for up to 30 s.
/// - On iOS 26, 10 s after backgrounding while an upload is moving, a continued-processing task
///   shows progress in the system UI and keeps the app running until the sends finish. If the
///   system or the user stops it first, the sends whose upload was under way are deleted (Mo,
///   2026-11-15, as Telegram does). Sends that were only waiting for the network stay queued:
///   being offline never fails a send.
/// - While either kind of background time is held, the realtime connection stays open.
///
/// Without background time the process is suspended; sends then wait and resume on return.
@MainActor
final class BackgroundSends {
  static let shared = BackgroundSends()

  static let submissionDelay: Duration = .seconds(10)
  static let maxBackgroundTaskSeconds: TimeInterval = 30

  private let log = Log.scoped("BackgroundSends")
  private var started = false
  private var pending: [PendingMediaSend] = []
  /// A launch in the background (a push) counts as foreground: background time is only taken
  /// after the user leaves the app.
  private var inForeground = true
  private var cancellables: Set<AnyCancellable> = []

  private var connectionRetained = false
  private var retentionTail: Task<Void, Never>?
  private var pendingRelease: Task<Void, Never>?
  /// On return the hold outlives the connection manager's own "active" signal, which arrives
  /// after `willEnterForeground`: released before it, with the background lease long gone, the
  /// manager would close the transport and break the upload in flight.
  static let foregroundReleaseDelay: Duration = .seconds(3)

  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var backgroundTaskUsed = false
  private var backgroundTaskTimer: Task<Void, Never>?

  private var submissionTimer: Task<Void, Never>?
  private var continued: AnyObject?
  private var nextContinuedNumber = 0

  func start() {
    guard !started else { return }
    started = true
    PendingMediaSends.shared.publisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] sends in
        MainActor.assumeIsolated {
          self?.pending = sends
          self?.update()
        }
      }
      .store(in: &cancellables)
    let center = NotificationCenter.default
    center.publisher(for: UIApplication.didEnterBackgroundNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.setForeground(false) } }
      .store(in: &cancellables)
    center.publisher(for: UIApplication.willEnterForegroundNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.setForeground(true) } }
      .store(in: &cancellables)
  }

  /// A push woke the app: as Telegram does, sends still pending get another stretch of
  /// background time.
  func pushReceived() {
    guard !inForeground, backgroundTask == .invalid else { return }
    backgroundTaskUsed = false
    update()
  }

  private func setForeground(_ value: Bool) {
    guard value != inForeground else { return }
    inForeground = value
    if value { backgroundTaskUsed = false }
    update()
  }

  private func update() {
    if inForeground || pending.isEmpty {
      endBackgroundTask()
    } else {
      beginBackgroundTaskIfNeeded()
    }
    if #available(iOS 26.0, *) {
      updateContinuedTask()
    }
    updateConnectionRetention()
  }

  // MARK: - Connection

  /// Only while background time is actually held: a hold without it would keep a socket the
  /// suspended process can't use, and skip the reconnect on return.
  private func updateConnectionRetention() {
    var holdsTime = backgroundTask != .invalid
    if #available(iOS 26.0, *), continuedTask?.launched == true { holdsTime = true }
    let retain = !inForeground && !pending.isEmpty && holdsTime
    if retain {
      pendingRelease?.cancel()
      pendingRelease = nil
      setConnectionRetained(true)
    } else if connectionRetained, inForeground {
      guard pendingRelease == nil else { return }
      pendingRelease = Task { [weak self] in
        try? await Task.sleep(for: Self.foregroundReleaseDelay)
        guard !Task.isCancelled, let self else { return }
        pendingRelease = nil
        setConnectionRetained(false)
      }
    } else {
      pendingRelease?.cancel()
      pendingRelease = nil
      setConnectionRetained(false)
    }
  }

  private func setConnectionRetained(_ retain: Bool) {
    guard retain != connectionRetained else { return }
    connectionRetained = retain
    let previous = retentionTail
    retentionTail = Task {
      await previous?.value
      await Api.realtime.setSendRetention(retain)
    }
  }

  // MARK: - Background task

  private func beginBackgroundTaskIfNeeded() {
    // One per background stay: iOS grants about 30 s in all, and asking again after it ran out
    // only gets a task that expires at once.
    guard backgroundTask == .invalid, !backgroundTaskUsed else { return }
    let identifier = UIApplication.shared.beginBackgroundTask(withName: "Sending messages") { [weak self] in
      MainActor.assumeIsolated { self?.endBackgroundTask() }
    }
    guard identifier != .invalid else { return }
    backgroundTask = identifier
    backgroundTaskUsed = true
    let seconds = min(Self.maxBackgroundTaskSeconds, max(0, UIApplication.shared.backgroundTimeRemaining - 5))
    log.debug("Holding background time for \(pending.count) sends, up to \(Int(seconds)) s")
    backgroundTaskTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    backgroundTaskTimer?.cancel()
    backgroundTaskTimer = nil
    guard backgroundTask != .invalid else { return }
    let identifier = backgroundTask
    backgroundTask = .invalid
    UIApplication.shared.endBackgroundTask(identifier)
    updateConnectionRetention()
  }

  // MARK: - Continued processing (iOS 26)

  @available(iOS 26.0, *)
  fileprivate var continuedTask: ContinuedSends? {
    get { continued as? ContinuedSends }
    set { continued = newValue }
  }

  @available(iOS 26.0, *)
  private func updateContinuedTask() {
    if !inForeground, !pending.isEmpty {
      guard continuedTask == nil, submissionTimer == nil else { return }
      // Checks every 10 s, so a send that starts moving once the network is back still gets one.
      submissionTimer = Task { [weak self] in
        while true {
          try? await Task.sleep(for: Self.submissionDelay)
          guard !Task.isCancelled, let self else { return }
          await submitContinuedTaskIfUploading()
          guard !Task.isCancelled else { return }
          if continuedTask != nil || inForeground || pending.isEmpty {
            submissionTimer = nil
            return
          }
        }
      }
      return
    }
    submissionTimer?.cancel()
    submissionTimer = nil
    guard let current = continuedTask else { return }
    if pending.isEmpty, current.launched {
      // Done in the background: complete it as finished.
      current.finish()
    } else {
      // Back on screen: stop it without deleting anything.
      current.stopByApp()
      if !current.launched { continuedTask = nil }
    }
  }

  @available(iOS 26.0, *)
  private func submitContinuedTaskIfUploading() async {
    // Only for uploads that are moving: a send waiting for the network would show a stalled
    // task the system may expire, and expiry deletes.
    let fractions = await FileUploader.shared.uploadFractions(for: pending.flatMap(\.media))
    let uploading = fractions.contains { ($0 ?? 0) > 0 && ($0 ?? 0) < 1 }
    guard uploading, !inForeground, !pending.isEmpty, continuedTask == nil,
          let bundleID = Bundle.main.bundleIdentifier else { return }
    nextContinuedNumber += 1
    // Registered by exact identifier, as Telegram does: a wildcard registration doesn't match
    // submitted ids on some iOS 26 builds. Info.plist permits `<bundle>.upload.*`.
    let identifier = "\(bundleID).upload.message\(nextContinuedNumber)"
    let continued = ContinuedSends(identifier: identifier, owner: self)
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
      MainActor.assumeIsolated {
        guard let task = task as? BGContinuedProcessingTask else {
          task.setTaskCompleted(success: true)
          return
        }
        continued.run(task)
      }
    }
    guard registered else {
      log.warning("Could not register continued processing task \(identifier)")
      return
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: Self.title(count: pending.count),
      subtitle: Self.subtitle
    )
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
      continuedTask = continued
      log.info("Submitted continued processing task for \(pending.count) sends")
    } catch {
      log.warning("Continued processing task not submitted: \(error.localizedDescription)")
    }
  }

  @available(iOS 26.0, *)
  fileprivate func continuedTaskLaunched() {
    updateConnectionRetention()
  }

  @available(iOS 26.0, *)
  fileprivate func continuedTaskEnded(_ ended: ContinuedSends) {
    if continuedTask === ended { continuedTask = nil }
    update()
  }

  fileprivate var pendingSends: [PendingMediaSend] { pending }
  fileprivate var isInForeground: Bool { inForeground }

  static func title(count: Int) -> String {
    count == 1 ? "Sending 1 message" : "Sending \(count) messages"
  }

  static let subtitle = "Uploading media"
}

/// One submitted continued-processing task: reports progress every second and completes when
/// the sends are done.
@available(iOS 26.0, *)
@MainActor
private final class ContinuedSends {
  let identifier: String
  private weak var owner: BackgroundSends?
  private(set) var launched = false
  private var task: BGContinuedProcessingTask?
  private var sendIDs: Set<String> = []
  /// Upload fractions seen on the last report, and when each send's last went up.
  private var lastFractions: [String: Double] = [:]
  private var lastMoved: [String: ContinuousClock.Instant] = [:]
  /// A send whose upload hasn't moved for this long is waiting (network lost mid-upload), not
  /// uploading, and expiry leaves it queued.
  static let movingWindow: Duration = .seconds(15)
  private var stoppedByApp = false
  private var ended = false
  private var progress = PendingSendsProgress()
  private var loop: Task<Void, Never>?

  init(identifier: String, owner: BackgroundSends) {
    self.identifier = identifier
    self.owner = owner
  }

  func run(_ task: BGContinuedProcessingTask) {
    launched = true
    self.task = task
    task.expirationHandler = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.expired() }
      }
    }
    // Stopped before it launched, or replaced: end it at once.
    guard !stoppedByApp, let owner, owner.continuedTask === self else {
      finish()
      return
    }
    sendIDs.formUnion(owner.pendingSends.map(\.transactionId))
    owner.continuedTaskLaunched()
    loop = Task { [weak self] in
      while let self, !self.ended {
        guard let owner = self.owner, !owner.pendingSends.isEmpty else {
          self.finish()
          return
        }
        if !owner.isInForeground {
          await self.report(owner.pendingSends)
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// Asks the system to end the task; its expiration then deletes nothing.
  func stopByApp() {
    guard !stoppedByApp, !ended else { return }
    stoppedByApp = true
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
  }

  func finish() {
    guard !ended else { return }
    ended = true
    loop?.cancel()
    if let task {
      task.updateTitle(task.title, subtitle: "Sent")
      task.setTaskCompleted(success: true)
    }
    owner?.continuedTaskEnded(self)
  }

  private func report(_ sends: [PendingMediaSend]) async {
    // One hop to the uploader for every item.
    var values = await FileUploader.shared.uploadFractions(for: sends.flatMap(\.media))[...]
    var fractions: [String: Double] = [:]
    for send in sends {
      let items = values.prefix(send.media.count)
      values = values.dropFirst(send.media.count)
      let sum = items.reduce(0.0) { $0 + ($1 ?? 0) }
      fractions[send.transactionId] = send.media.isEmpty ? 0 : sum / Double(send.media.count)
    }
    guard !ended, let task else { return }
    sendIDs.formUnion(fractions.keys)
    let now = ContinuousClock.now
    for (id, fraction) in fractions where fraction > (lastFractions[id] ?? 0) {
      lastMoved[id] = now
    }
    lastFractions = fractions
    progress.update(fractions)
    let units = progress.units
    task.progress.totalUnitCount = units.total
    task.progress.completedUnitCount = units.completed
    let title = BackgroundSends.title(count: sends.count)
    if task.title != title {
      task.updateTitle(title, subtitle: BackgroundSends.subtitle)
    }
  }

  private func expired() {
    guard !ended else { return }
    ended = true
    loop?.cancel()
    if !stoppedByApp {
      // Sends whose upload was moving, with the rest of their album; see `expiredSendsToDelete`.
      let unsent = PendingMediaSends.expiredSendsToDelete(
        current: PendingMediaSends.shared.current,
        taskSendIDs: sendIDs,
        fractions: lastFractions,
        lastMoved: lastMoved,
        now: .now,
        movingWindow: Self.movingWindow
      )
      Log.scoped("BackgroundSends").warning("Continued processing task expired; deleting \(unsent.count) unsent messages")
      // Rows go before the task completes: the process may be killed right after, and a row
      // still sending would be resumed on the next launch.
      PendingMediaSends.deleteUnsent(unsent)
    }
    task?.setTaskCompleted(success: false)
    owner?.continuedTaskEnded(self)
  }
}
