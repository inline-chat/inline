#if os(iOS)
import Logger
import UIKit

/// Holds background time while downloads run, as `BackgroundSends` does for sends: a download
/// that is close to done when the user locks the phone or switches away gets about 30 s more to
/// finish. Whatever is left stays in its partial file and continues on return.
@MainActor
final class BackgroundDownloadTime {
  private static let maxSeconds: Double = 30

  private var active = false
  private var inForeground = UIApplication.shared.applicationState != .background
  private var task: UIBackgroundTaskIdentifier = .invalid
  /// iOS grants about 30 s per background stay; asking again after it ran out only gets a task
  /// that expires at once.
  private var usedThisStay = false
  private var timer: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private let log = Log.scoped("BackgroundDownloads")

  init() {
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.setForeground(false) }
      },
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.setForeground(true) }
      },
    ]
  }

  isolated deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    end()
  }

  func setActive(_ value: Bool) {
    guard value != active else { return }
    active = value
    update()
  }

  private func setForeground(_ value: Bool) {
    guard value != inForeground else { return }
    inForeground = value
    if value { usedThisStay = false }
    update()
  }

  private func update() {
    if inForeground || !active { end() } else { begin() }
  }

  private func begin() {
    guard task == .invalid, !usedThisStay else { return }
    let identifier = UIApplication.shared.beginBackgroundTask(withName: "Downloading files") { [weak self] in
      MainActor.assumeIsolated { self?.end() }
    }
    guard identifier != .invalid else { return }
    task = identifier
    usedThisStay = true
    let seconds = min(Self.maxSeconds, max(0, UIApplication.shared.backgroundTimeRemaining - 5))
    log.debug("Holding background time for downloads, up to \(Int(seconds)) s")
    timer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.end()
    }
  }

  private func end() {
    timer?.cancel()
    timer = nil
    guard task != .invalid else { return }
    let identifier = task
    task = .invalid
    UIApplication.shared.endBackgroundTask(identifier)
  }
}
#endif
