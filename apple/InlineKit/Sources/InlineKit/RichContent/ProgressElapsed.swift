import Foundation

/// The live "Working 2m 12s" time on a progress row.
///
/// Bots send when the work started (`BlockDisclosure.startedAt`); rows without it count from
/// the message's own time. The format matches the Inline CLI bridge's "Worked for" line, so
/// the number doesn't jump when the row closes.
public enum ProgressElapsed {
  /// Past this, the work is almost certainly dead; the row stops showing a time.
  public static let cap: TimeInterval = 12 * 3600

  /// The widest text the time can show, for reserving its width up front.
  public static let widestSamples = ["00m 00s", "00h 00m"]

  /// Seconds since `start`, never negative, or nil past the cap.
  public static func seconds(since start: Date, now: Date = Date()) -> TimeInterval? {
    let elapsed = max(0, now.timeIntervalSince(start))
    return elapsed > cap ? nil : elapsed
  }

  /// "8s", "1m 4s", "1h 2m", as the bridge writes it.
  public static func text(seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    if total < 60 { return "\(max(1, total))s" }
    if total < 3600 { return "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \((total % 3600) / 60)m"
  }

  /// The row's time now, or nil when it shouldn't show one.
  public static func text(since start: Date, now: Date = Date()) -> String? {
    seconds(since: start, now: now).map { text(seconds: $0) }
  }

  /// When a progress row's work started: its own start, else the message's time.
  public static func start(startedAt: Int64?, messageDate: Date) -> Date {
    guard let startedAt, startedAt > 0 else { return messageDate }
    return Date(timeIntervalSince1970: TimeInterval(startedAt))
  }
}

/// One once-a-second clock for every visible live time, so rows don't each run a timer.
/// It runs only while something listens, and fires on whole seconds so rows tick together.
@MainActor
public final class ProgressElapsedTicker {
  public static let shared = ProgressElapsedTicker()

  private struct Listener {
    weak var owner: AnyObject?
    let tick: @MainActor () -> Void
  }

  private var listeners: [ObjectIdentifier: Listener] = [:]
  private var timer: Timer?

  private init() {}

  /// Calls `tick` every second until `remove(_:)` with the same owner, or until the owner
  /// is gone. One entry per owner.
  public func add(_ owner: AnyObject, tick: @escaping @MainActor () -> Void) {
    listeners[ObjectIdentifier(owner)] = Listener(owner: owner, tick: tick)
    startIfNeeded()
  }

  public func remove(_ owner: AnyObject) {
    listeners[ObjectIdentifier(owner)] = nil
    stopIfIdle()
  }

  private func stopIfIdle() {
    guard listeners.isEmpty else { return }
    timer?.invalidate()
    timer = nil
  }

  private func startIfNeeded() {
    guard timer == nil else { return }
    let now = Date().timeIntervalSince1970
    let next = Date(timeIntervalSince1970: now.rounded(.down) + 1)
    let timer = Timer(fire: next, interval: 1, repeats: true) { _ in
      MainActor.assumeIsolated { ProgressElapsedTicker.shared.fire() }
    }
    timer.tolerance = 0.05
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func fire() {
    for (id, listener) in listeners where listener.owner == nil {
      listeners[id] = nil
    }
    for listener in Array(listeners.values) {
      listener.tick()
    }
    stopIfIdle()
  }
}
