import Foundation

// Backports of `Swift.Duration`, `ContinuousClock` and `SuspendingClock` (iOS 16, macOS 13).
//
// The types are always compiled and tested as `CompatDuration` / `CompatContinuousClock` /
// `CompatSuspendingClock`. On platforms whose deployment target predates the native types
// (iOS here; macOS already targets 15), typealiases named `Duration`, `ContinuousClock` and
// `SuspendingClock` shadow the standard library for every file that imports InlineCompat, so
// call sites like `try await Task.sleep(for: .milliseconds(250))` compile unchanged.
//
// The API is a strict subset of the native one, so deleting the typealiases (when the iOS
// deployment target reaches 16) switches every call site back to the standard library.

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
public typealias Duration = CompatDuration
public typealias ContinuousClock = CompatContinuousClock
public typealias SuspendingClock = CompatSuspendingClock
#endif

// MARK: - Duration

/// Nanosecond-precision duration. Covers ±292 years, which is plenty for app timing.
public struct CompatDuration: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
  /// Total length in nanoseconds.
  public var nanosecondsValue: Int64

  @inlinable
  public init(nanosecondsValue: Int64) {
    self.nanosecondsValue = nanosecondsValue
  }

  public init(secondsComponent: Int64, attosecondsComponent: Int64) {
    nanosecondsValue = secondsComponent &* 1_000_000_000 &+ attosecondsComponent / 1_000_000_000
  }

  public static let zero = CompatDuration(nanosecondsValue: 0)

  /// `(seconds, attoseconds)` like `Swift.Duration.components`. Attoseconds share the sign of
  /// the duration, matching the standard library.
  public var components: (seconds: Int64, attoseconds: Int64) {
    let seconds = nanosecondsValue / 1_000_000_000
    let remainder = nanosecondsValue % 1_000_000_000
    return (seconds, remainder * 1_000_000_000)
  }

  public var description: String {
    let (seconds, attoseconds) = components
    if attoseconds == 0 { return "\(seconds).0 seconds" }
    return "\(Double(nanosecondsValue) / 1e9) seconds"
  }

  // MARK: Factories

  @inlinable
  public static func seconds<T: BinaryInteger>(_ seconds: T) -> CompatDuration {
    CompatDuration(nanosecondsValue: Int64(seconds) &* 1_000_000_000)
  }

  @inlinable
  public static func seconds(_ seconds: Double) -> CompatDuration {
    CompatDuration(nanosecondsValue: saturatingNanoseconds(seconds * 1e9))
  }

  @inlinable
  public static func milliseconds<T: BinaryInteger>(_ milliseconds: T) -> CompatDuration {
    CompatDuration(nanosecondsValue: Int64(milliseconds) &* 1_000_000)
  }

  @inlinable
  public static func milliseconds(_ milliseconds: Double) -> CompatDuration {
    CompatDuration(nanosecondsValue: saturatingNanoseconds(milliseconds * 1e6))
  }

  @inlinable
  public static func microseconds<T: BinaryInteger>(_ microseconds: T) -> CompatDuration {
    CompatDuration(nanosecondsValue: Int64(microseconds) &* 1_000)
  }

  @inlinable
  public static func microseconds(_ microseconds: Double) -> CompatDuration {
    CompatDuration(nanosecondsValue: saturatingNanoseconds(microseconds * 1e3))
  }

  @inlinable
  public static func nanoseconds<T: BinaryInteger>(_ nanoseconds: T) -> CompatDuration {
    CompatDuration(nanosecondsValue: Int64(nanoseconds))
  }

  @usableFromInline
  static func saturatingNanoseconds(_ value: Double) -> Int64 {
    guard value.isFinite else { return value > 0 ? .max : .min }
    if value >= Double(Int64.max) { return .max }
    if value <= Double(Int64.min) { return .min }
    return Int64(value.rounded(.towardZero))
  }

  // MARK: Arithmetic

  public static func < (lhs: CompatDuration, rhs: CompatDuration) -> Bool {
    lhs.nanosecondsValue < rhs.nanosecondsValue
  }

  public static func + (lhs: CompatDuration, rhs: CompatDuration) -> CompatDuration {
    CompatDuration(nanosecondsValue: lhs.nanosecondsValue &+ rhs.nanosecondsValue)
  }

  public static func - (lhs: CompatDuration, rhs: CompatDuration) -> CompatDuration {
    CompatDuration(nanosecondsValue: lhs.nanosecondsValue &- rhs.nanosecondsValue)
  }

  public static prefix func - (duration: CompatDuration) -> CompatDuration {
    CompatDuration(nanosecondsValue: 0 &- duration.nanosecondsValue)
  }

  public static func += (lhs: inout CompatDuration, rhs: CompatDuration) { lhs = lhs + rhs }
  public static func -= (lhs: inout CompatDuration, rhs: CompatDuration) { lhs = lhs - rhs }

  public static func * <T: BinaryInteger>(lhs: CompatDuration, rhs: T) -> CompatDuration {
    CompatDuration(nanosecondsValue: lhs.nanosecondsValue &* Int64(rhs))
  }

  public static func * <T: BinaryInteger>(lhs: T, rhs: CompatDuration) -> CompatDuration {
    rhs * lhs
  }

  public static func * (lhs: CompatDuration, rhs: Double) -> CompatDuration {
    CompatDuration(nanosecondsValue: saturatingNanoseconds(Double(lhs.nanosecondsValue) * rhs))
  }

  public static func *= <T: BinaryInteger>(lhs: inout CompatDuration, rhs: T) { lhs = lhs * rhs }

  public static func / <T: BinaryInteger>(lhs: CompatDuration, rhs: T) -> CompatDuration {
    CompatDuration(nanosecondsValue: lhs.nanosecondsValue / Int64(rhs))
  }

  public static func / (lhs: CompatDuration, rhs: Double) -> CompatDuration {
    CompatDuration(nanosecondsValue: saturatingNanoseconds(Double(lhs.nanosecondsValue) / rhs))
  }

  public static func /= <T: BinaryInteger>(lhs: inout CompatDuration, rhs: T) { lhs = lhs / rhs }

  public static func / (lhs: CompatDuration, rhs: CompatDuration) -> Double {
    Double(lhs.nanosecondsValue) / Double(rhs.nanosecondsValue)
  }

  // MARK: Conversions (not on Swift.Duration; use only in compat-aware code)

  /// Seconds as `TimeInterval`.
  public var compatTimeInterval: TimeInterval { Double(nanosecondsValue) / 1e9 }

  /// Clamped to zero, for `Task.sleep(nanoseconds:)` and dispatch APIs.
  public var compatNonNegativeNanoseconds: UInt64 { UInt64(max(0, nanosecondsValue)) }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension CompatDuration {
  public init(_ duration: Swift.Duration) {
    let (seconds, attoseconds) = duration.components
    self.init(secondsComponent: seconds, attosecondsComponent: attoseconds)
  }

  public var swiftDuration: Swift.Duration {
    let (seconds, attoseconds) = components
    return Swift.Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
  }
}

// MARK: - Clocks

/// Monotonic clock that keeps counting while the device sleeps (`mach_continuous_time`).
public struct CompatContinuousClock: Sendable {
  public struct Instant: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Nanoseconds since an arbitrary boot-relative epoch.
    public var uptimeNanoseconds: Int64

    public init(uptimeNanoseconds: Int64) { self.uptimeNanoseconds = uptimeNanoseconds }

    public static var now: Instant { CompatContinuousClock.now }

    public func advanced(by duration: CompatDuration) -> Instant {
      Instant(uptimeNanoseconds: uptimeNanoseconds &+ duration.nanosecondsValue)
    }

    public func duration(to other: Instant) -> CompatDuration {
      CompatDuration(nanosecondsValue: other.uptimeNanoseconds &- uptimeNanoseconds)
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    public static func + (lhs: Instant, rhs: CompatDuration) -> Instant { lhs.advanced(by: rhs) }
    public static func - (lhs: Instant, rhs: CompatDuration) -> Instant { lhs.advanced(by: -rhs) }
    public static func - (lhs: Instant, rhs: Instant) -> CompatDuration { rhs.duration(to: lhs) }
    public static func += (lhs: inout Instant, rhs: CompatDuration) { lhs = lhs + rhs }
    public static func -= (lhs: inout Instant, rhs: CompatDuration) { lhs = lhs - rhs }

    public var description: String { "Instant(\(uptimeNanoseconds)ns)" }
  }

  public init() {}

  public static var now: Instant { Instant(uptimeNanoseconds: MachTime.continuousNanoseconds()) }
  public var now: Instant { Self.now }
  public var minimumResolution: CompatDuration { .nanoseconds(1) }

  public func sleep(until deadline: Instant, tolerance: CompatDuration? = nil) async throws {
    try await Task.sleep(nanoseconds: now.duration(to: deadline).compatNonNegativeNanoseconds)
  }

  public func sleep(for duration: CompatDuration, tolerance: CompatDuration? = nil) async throws {
    try await Task.sleep(nanoseconds: duration.compatNonNegativeNanoseconds)
  }

  public func measure(_ work: () throws -> Void) rethrows -> CompatDuration {
    let start = now
    try work()
    return start.duration(to: now)
  }

  public func measure(
    isolation: isolated (any Actor)? = #isolation,
    _ work: () async throws -> Void
  ) async rethrows -> CompatDuration {
    let start = now
    try await work()
    return start.duration(to: now)
  }
}

/// Monotonic clock that pauses while the device sleeps (`mach_absolute_time`).
public struct CompatSuspendingClock: Sendable {
  public struct Instant: Sendable, Hashable, Comparable {
    public var uptimeNanoseconds: Int64

    public init(uptimeNanoseconds: Int64) { self.uptimeNanoseconds = uptimeNanoseconds }

    public static var now: Instant { CompatSuspendingClock.now }

    public func advanced(by duration: CompatDuration) -> Instant {
      Instant(uptimeNanoseconds: uptimeNanoseconds &+ duration.nanosecondsValue)
    }

    public func duration(to other: Instant) -> CompatDuration {
      CompatDuration(nanosecondsValue: other.uptimeNanoseconds &- uptimeNanoseconds)
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    public static func + (lhs: Instant, rhs: CompatDuration) -> Instant { lhs.advanced(by: rhs) }
    public static func - (lhs: Instant, rhs: CompatDuration) -> Instant { lhs.advanced(by: -rhs) }
    public static func - (lhs: Instant, rhs: Instant) -> CompatDuration { rhs.duration(to: lhs) }
  }

  public init() {}

  public static var now: Instant { Instant(uptimeNanoseconds: MachTime.absoluteNanoseconds()) }
  public var now: Instant { Self.now }

  public func sleep(until deadline: Instant, tolerance: CompatDuration? = nil) async throws {
    try await Task.sleep(nanoseconds: now.duration(to: deadline).compatNonNegativeNanoseconds)
  }

  public func sleep(for duration: CompatDuration, tolerance: CompatDuration? = nil) async throws {
    try await Task.sleep(nanoseconds: duration.compatNonNegativeNanoseconds)
  }

  public func measure(_ work: () throws -> Void) rethrows -> CompatDuration {
    let start = now
    try work()
    return start.duration(to: now)
  }
}

// MARK: - Task.sleep

extension Task where Success == Never, Failure == Never {
  /// `Task.sleep(for:)` for the compat duration. Shadows the iOS 16 API on iOS.
  public static func sleep(
    for duration: CompatDuration,
    tolerance: CompatDuration? = nil
  ) async throws {
    try await Task.sleep(nanoseconds: duration.compatNonNegativeNanoseconds)
  }

  public static func sleep(
    until deadline: CompatContinuousClock.Instant,
    tolerance: CompatDuration? = nil,
    clock: CompatContinuousClock = CompatContinuousClock()
  ) async throws {
    try await clock.sleep(until: deadline, tolerance: tolerance)
  }

  public static func sleep(
    until deadline: CompatSuspendingClock.Instant,
    tolerance: CompatDuration? = nil,
    clock: CompatSuspendingClock
  ) async throws {
    try await clock.sleep(until: deadline, tolerance: tolerance)
  }
}

// MARK: - Mach time

@usableFromInline
enum MachTime {
  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  static func continuousNanoseconds() -> Int64 {
    toNanoseconds(mach_continuous_time())
  }

  static func absoluteNanoseconds() -> Int64 {
    toNanoseconds(mach_absolute_time())
  }

  private static func toNanoseconds(_ ticks: UInt64) -> Int64 {
    let info = timebase
    if info.numer == info.denom { return Int64(truncatingIfNeeded: ticks) }
    // 128-bit intermediate so long uptimes cannot overflow.
    let product = ticks.multipliedFullWidth(by: UInt64(info.numer))
    let (quotient, _) = UInt64(info.denom).dividingFullWidth(product)
    return Int64(truncatingIfNeeded: quotient)
  }
}
