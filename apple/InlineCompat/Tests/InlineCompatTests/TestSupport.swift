import Dispatch
import Foundation
@testable import InlineCompat
import Testing

#if canImport(Observation)
import Observation
#endif

// MARK: - Waiting

/// Lets every block already queued on the main queue run before returning.
@MainActor
func drainMainQueue(turns: Int = 1) async {
  for _ in 0 ..< turns {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async { continuation.resume() }
    }
  }
}

/// Polls `condition` once per main-queue turn until it holds or `timeout` passes.
@MainActor
@discardableResult
func waitUntil(
  timeout: Swift.Duration = .seconds(2),
  _ condition: @MainActor () -> Bool
) async -> Bool {
  let clock = Swift.ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition() {
    if clock.now >= deadline { return condition() }
    await drainMainQueue()
  }
  return true
}

/// Blocking poll for code that is not on the main actor.
@discardableResult
func spinUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    if Date() >= deadline { return condition() }
    usleep(500)
  }
  return true
}

/// Runs `body` on a fresh `Thread` and blocks until it finishes.
func runOnNewThread(_ body: @escaping @Sendable () -> Void) {
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    body()
    done.signal()
  }
  thread.start()
  done.wait()
}

// MARK: - Recording

/// Thread-safe list of values seen by handlers that may run on any thread.
final class Recorder<Element: Sendable>: Sendable {
  private let storage = Mutex<[Element]>([])

  func append(_ element: Element) { storage.withLock { $0.append(element) } }
  var values: [Element] { storage.withLock { $0 } }
  var count: Int { storage.withLock { $0.count } }
}

final class Sentinel: Sendable {}

// MARK: - Observation subjects

/// Which registrar path a test subject exercises.
enum SubjectKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// Declares `Observable`, default registrar: native `ObservationRegistrar` on macOS 14+.
  case native
  /// Declares `Observable` but the registrar is forced onto the fallback path.
  case forcedFallback
  /// No `Observable` conformance at all, like a model on iOS 15/16.
  case plain

  var testDescription: String { rawValue }
}

protocol TestSubject: CompatObservable, Sendable {
  var count: Int { get set }
  var name: String { get set }
  var other: Int { get set }
  /// Plain stored property, like `@ObservationIgnored`.
  var untracked: Int { get set }
  /// Computed property that reports through `access` / `willSet` / `didSet` by hand.
  var manual: Int { get set }
}

final class ObservableSubject: TestSubject, @unchecked Sendable {
  let observationRegistrar: CompatObservationRegistrar

  @Tracked var count = 0
  @Tracked var name = ""
  @Tracked var other = 0
  var untracked = 0

  private var manualStorage = 0
  var manual: Int {
    get {
      observationRegistrar.access(self, keyPath: \.manual)
      return manualStorage
    }
    set {
      observationRegistrar.willSet(self, keyPath: \.manual)
      manualStorage = newValue
      observationRegistrar.didSet(self, keyPath: \.manual)
    }
  }

  init(forceFallback: Bool) {
    observationRegistrar = CompatObservationRegistrar(forceFallback: forceFallback)
  }

  /// Uses the convenience initializer, which honours `forcesFallbackForTesting`.
  init() {
    observationRegistrar = CompatObservationRegistrar()
  }
}

@available(macOS 14.0, iOS 17.0, *)
extension ObservableSubject: Observable {}

final class PlainSubject: TestSubject, @unchecked Sendable {
  let observationRegistrar = CompatObservationRegistrar(forceFallback: false)

  @Tracked var count = 0
  @Tracked var name = ""
  @Tracked var other = 0
  var untracked = 0

  private var manualStorage = 0
  var manual: Int {
    get {
      observationRegistrar.access(self, keyPath: \.manual)
      return manualStorage
    }
    set {
      observationRegistrar.willSet(self, keyPath: \.manual)
      manualStorage = newValue
      observationRegistrar.didSet(self, keyPath: \.manual)
    }
  }
}

/// Main-actor model, the shape the doc comment recommends for view models.
@MainActor
final class MainActorModel: CompatObservable {
  let observationRegistrar = CompatObservationRegistrar(forceFallback: false)
  @Tracked var title = "a"
  @Tracked private(set) var items: [Int] = []

  func append(_ item: Int) { items.append(item) }
}

@available(macOS 14.0, iOS 17.0, *)
extension MainActorModel: Observable {}

func makeSubject(_ kind: SubjectKind) -> any TestSubject {
  switch kind {
  case .native: ObservableSubject(forceFallback: false)
  case .forcedFallback: ObservableSubject(forceFallback: true)
  case .plain: PlainSubject()
  }
}

extension CompatObservable {
  /// Live fallback observers on this subject's registrar.
  var fallbackObserverCount: Int { observationRegistrar.fallback.observerCount }
}

extension TestSubject {
  /// Opens the existential so the generic `usesNativeRegistrar(for:)` gets a concrete class.
  var usesNativeRegistrar: Bool { observationRegistrar.usesNativeRegistrar(for: self) }
}

extension SubjectKind {
  /// Fallback observers expected for `scopes` live scopes on one subject. Native subjects are
  /// tracked by the native registrar only, so their fallback registrar stays empty.
  func fallbackObservers(_ scopes: Int) -> Int { self == .native ? 0 : scopes }
}
