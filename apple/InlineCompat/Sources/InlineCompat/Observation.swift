import Foundation
#if canImport(Observation)
import Observation
#endif

// Observation backport (native Observation is iOS 17, macOS 14).
//
// Model classes adopt it without macros:
//
//     @MainActor
//     public final class SearchModel: CompatObservable {
//       public let observationRegistrar = CompatObservationRegistrar()
//       @Tracked public var query = ""
//       @Tracked public private(set) var results: [Result] = []
//       public var cache: [String: Result] = [:]        // untracked, like @ObservationIgnored
//     }
//     @available(iOS 17.0, macOS 14.0, *)
//     extension SearchModel: Observable {}
//
// When the running OS has native Observation and the class declares `Observable`, every read
// and write goes through a real `ObservationRegistrar`, so SwiftUI (`@Bindable`,
// `@Environment(Model.self)`, `@State`) and `withObservationTracking` work natively. On older
// systems the registrar records reads into the current `withCompatObservationTracking` scope and
// fires its change handler on `willSet`, the same contract as the native API.
//
// UIKit code observes with `withCompatObservationTracking` (one shot) or
// `CompatObservation.observe` (re-runs on every change), which use the native tracker when it
// is available and the fallback otherwise.

/// A class whose `@Tracked` properties report reads and writes to `observationRegistrar`.
public protocol CompatObservable: AnyObject {
  var observationRegistrar: CompatObservationRegistrar { get }
}

// MARK: - @Tracked

@propertyWrapper
public struct Tracked<Value> {
  @usableFromInline var storage: Value

  @inlinable
  public init(wrappedValue: Value) {
    storage = wrappedValue
  }

  @available(*, unavailable, message: "@Tracked can only be used on properties of a CompatObservable class")
  public var wrappedValue: Value {
    get { fatalError() }
    set { fatalError() }
  }

  @inlinable
  public static subscript<Subject: CompatObservable>(
    _enclosingInstance subject: Subject,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<Subject, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<Subject, Tracked<Value>>
  ) -> Value {
    get {
      subject.observationRegistrar.access(subject, keyPath: wrappedKeyPath)
      return subject[keyPath: storageKeyPath].storage
    }
    set {
      subject.observationRegistrar.withMutation(of: subject, keyPath: wrappedKeyPath) {
        subject[keyPath: storageKeyPath].storage = newValue
      }
    }
  }
}

extension Tracked: Sendable where Value: Sendable {}

// MARK: - Registrar

public final class CompatObservationRegistrar: @unchecked Sendable {
  /// Lazily resolved per subject type: whether the native registrar can be used.
  private enum Mode: UInt8 { case unresolved, native, fallback }

  private let modeLock = Mutex(Mode.unresolved)
  private let nativeBox: AnyObject?
  @usableFromInline let fallback = FallbackRegistrar()

  /// Forces every new registrar onto the fallback path, so newer systems can exercise the
  /// iOS 15/16 behaviour (tests, or a debug toggle on a current device).
  nonisolated(unsafe) public static var forcesFallbackForTesting = false

  private let forcesFallback: Bool

  public convenience init() {
    self.init(forceFallback: Self.forcesFallbackForTesting)
  }

  public init(forceFallback: Bool) {
    forcesFallback = forceFallback
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *), !forceFallback {
      nativeBox = NativeRegistrarBox()
    } else {
      nativeBox = nil
    }
  }

  /// True when reads and writes go through the native `ObservationRegistrar`.
  public func usesNativeRegistrar<Subject: AnyObject>(for subject: Subject) -> Bool {
    mode(for: subject) == .native
  }

  private func mode<Subject: AnyObject>(for subject: Subject) -> Mode {
    let current = modeLock.withLock { $0 }
    if current != .unresolved { return current }
    var resolved = Mode.fallback
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *), !forcesFallback, subject is any Observable {
      resolved = .native
    }
    modeLock.withLock { $0 = resolved }
    return resolved
  }

  public func access<Subject: AnyObject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    if mode(for: subject) == .native, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
      // Native subjects are tracked only natively: compat scopes always run inside
      // `withObservationTracking` when the native registrar exists. Recording them in the
      // fallback scope too would notify twice per mutation (fallback, then native willSet), and
      // a handler that re-subscribes from onChange would fire again for the same mutation.
      nativeAccess(subject, keyPath: keyPath)
    } else {
      FallbackTracking.recordAccess(registrar: fallback, keyPath: keyPath)
    }
  }

  public func withMutation<Subject: AnyObject, Member, T>(
    of subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ mutation: () -> T
  ) -> T {
    fallback.willSet(keyPath: keyPath)
    if mode(for: subject) == .native, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
      return nativeMutation(subject, keyPath: keyPath, mutation)
    }
    return mutation()
  }

  /// Use for mutations that bypass `@Tracked` (for example a manual backing store).
  public func willSet<Subject: AnyObject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    fallback.willSet(keyPath: keyPath)
    if mode(for: subject) == .native, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
      nativeWillSet(subject, keyPath: keyPath)
    }
  }

  public func didSet<Subject: AnyObject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    if mode(for: subject) == .native, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
      nativeDidSet(subject, keyPath: keyPath)
    }
  }

  // MARK: Native bridging

  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  private var native: ObservationRegistrar {
    unsafeDowncast(nativeBox!, to: NativeRegistrarBox.self).registrar
  }

  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  private func nativeAccess<Subject: AnyObject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    let observed = subject as! any Observable
    nativeAccessOpened(native, observed, keyPath: keyPath)
  }

  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  private func nativeMutation<Subject: AnyObject, Member, T>(
    _ subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ mutation: () -> T
  ) -> T {
    let observed = subject as! any Observable
    return nativeMutationOpened(native, observed, keyPath: keyPath, mutation)
  }

  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  private func nativeWillSet<Subject: AnyObject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    let observed = subject as! any Observable
    nativeWillSetOpened(native, observed, keyPath: keyPath)
  }

  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  private func nativeDidSet<Subject: AnyObject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    let observed = subject as! any Observable
    nativeDidSetOpened(native, observed, keyPath: keyPath)
  }
}

// The key path's root is the concrete subject type, which is exactly `Observed` once the
// existential is opened, so the bit cast only restates a type the compiler cannot see.

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
private func nativeAccessOpened<Observed: Observable, Root, Member>(
  _ registrar: ObservationRegistrar, _ observed: Observed, keyPath: KeyPath<Root, Member>
) {
  registrar.access(observed, keyPath: unsafeBitCast(keyPath, to: KeyPath<Observed, Member>.self))
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
private func nativeMutationOpened<Observed: Observable, Root, Member, T>(
  _ registrar: ObservationRegistrar, _ observed: Observed, keyPath: KeyPath<Root, Member>, _ mutation: () -> T
) -> T {
  registrar.withMutation(
    of: observed,
    keyPath: unsafeBitCast(keyPath, to: KeyPath<Observed, Member>.self),
    mutation
  )
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
private func nativeWillSetOpened<Observed: Observable, Root, Member>(
  _ registrar: ObservationRegistrar, _ observed: Observed, keyPath: KeyPath<Root, Member>
) {
  registrar.willSet(observed, keyPath: unsafeBitCast(keyPath, to: KeyPath<Observed, Member>.self))
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
private func nativeDidSetOpened<Observed: Observable, Root, Member>(
  _ registrar: ObservationRegistrar, _ observed: Observed, keyPath: KeyPath<Root, Member>
) {
  registrar.didSet(observed, keyPath: unsafeBitCast(keyPath, to: KeyPath<Observed, Member>.self))
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
private final class NativeRegistrarBox {
  let registrar = ObservationRegistrar()
}

// MARK: - Fallback registrar

@usableFromInline
final class FallbackRegistrar: @unchecked Sendable {
  private struct Observer {
    let keyPaths: Set<AnyKeyPath>
    let fire: @Sendable () -> Void
  }

  private struct State {
    var nextID = 0
    var observers: [Int: Observer] = [:]
  }

  private let state = Mutex(State())

  func addObserver(keyPaths: Set<AnyKeyPath>, fire: @escaping @Sendable () -> Void) -> Int {
    state.withLock { state in
      state.nextID += 1
      state.observers[state.nextID] = Observer(keyPaths: keyPaths, fire: fire)
      return state.nextID
    }
  }

  func removeObserver(_ id: Int) {
    _ = state.withLock { $0.observers.removeValue(forKey: id) }
  }

  func willSet(keyPath: AnyKeyPath) {
    let toFire: [@Sendable () -> Void] = state.withLock { state in
      guard !state.observers.isEmpty else { return [] }
      return state.observers.values.compactMap { $0.keyPaths.contains(keyPath) ? $0.fire : nil }
    }
    for fire in toFire { fire() }
  }

  var observerCount: Int { state.withLock { $0.observers.count } }
}

/// Collects fallback accesses for the innermost tracking scope on the current thread.
enum FallbackTracking {
  final class Scope {
    var accesses: [ObjectIdentifier: (registrar: FallbackRegistrar, keyPaths: Set<AnyKeyPath>)] = [:]

    func merge(_ other: Scope) {
      for (id, access) in other.accesses {
        if accesses[id] == nil {
          accesses[id] = access
        } else {
          accesses[id]!.keyPaths.formUnion(access.keyPaths)
        }
      }
    }
  }

  private static let key: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
  }()

  static var current: Scope? {
    guard let raw = pthread_getspecific(key) else { return nil }
    return Unmanaged<Scope>.fromOpaque(raw).takeUnretainedValue()
  }

  static func withScope<T>(_ scope: Scope, _ body: () throws -> T) rethrows -> T {
    let previous = pthread_getspecific(key)
    pthread_setspecific(key, Unmanaged.passUnretained(scope).toOpaque())
    defer {
      pthread_setspecific(key, previous)
      // Like native `withObservationTracking`, a nested scope's reads also count for the
      // enclosing scope, so both paths behave the same.
      if let previous { Unmanaged<Scope>.fromOpaque(previous).takeUnretainedValue().merge(scope) }
    }
    return try withExtendedLifetime(scope) { try body() }
  }

  @inline(__always)
  static func recordAccess(registrar: FallbackRegistrar, keyPath: AnyKeyPath) {
    guard let scope = current else { return }
    let id = ObjectIdentifier(registrar)
    if scope.accesses[id] == nil {
      scope.accesses[id] = (registrar, [keyPath])
    } else {
      scope.accesses[id]!.keyPaths.insert(keyPath)
    }
  }
}

// MARK: - Tracking API

/// One-shot tracking with the same contract as `withObservationTracking`: `apply` runs now,
/// and `onChange` is called once, before the first change to anything `apply` read.
@discardableResult
public func withCompatObservationTracking<T>(
  _ apply: () -> T,
  onChange: @autoclosure () -> @Sendable () -> Void
) -> T {
  compatTrack(apply, onChange: onChange()).value
}

func compatTrack<T>(
  _ apply: () -> T,
  onChange handler: @escaping @Sendable () -> Void
) -> (value: T, registrations: RegistrationBag) {
  let once = OnceFlag()
  let fallbackScope = FallbackTracking.Scope()
  let registrations = RegistrationBag()

  let fireOnce: @Sendable () -> Void = {
    guard once.claim() else { return }
    registrations.cancelAll()
    handler()
  }

  let result: T
  if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
    result = withObservationTracking {
      FallbackTracking.withScope(fallbackScope, apply)
    } onChange: {
      fireOnce()
    }
  } else {
    result = FallbackTracking.withScope(fallbackScope, apply)
  }

  for (_, access) in fallbackScope.accesses {
    let registrar = access.registrar
    let id = registrar.addObserver(keyPaths: access.keyPaths, fire: fireOnce)
    // Weak: the observer's handler owns `registrations`, so a strong capture would keep the
    // registrar (and the handler) alive forever once the subject is gone.
    registrations.add { [weak registrar] in registrar?.removeObserver(id) }
  }
  if once.isClaimed { registrations.cancelAll() }
  return (result, registrations)
}

public enum CompatObservation {
  /// Runs `render` now and again after every change to anything it read, until the token is
  /// cancelled or released. Re-renders are coalesced onto the next main-queue turn.
  ///
  /// The first run is synchronous so views are filled before their first frame.
  @MainActor
  public static func observe(_ render: @escaping @MainActor () -> Void) -> CompatObservationToken {
    let loop = ObservationLoop(render: render)
    loop.run()
    return CompatObservationToken(loop: loop)
  }
}

/// Keeps an observation alive. Cancelled by `cancel()` or by releasing the token.
@MainActor
public final class CompatObservationToken {
  private var loop: ObservationLoop?

  fileprivate init(loop: ObservationLoop) {
    self.loop = loop
  }

  public func cancel() {
    loop?.cancel()
    loop = nil
  }

  public var isCancelled: Bool { loop == nil }
}

@MainActor
private final class ObservationLoop {
  private let render: @MainActor () -> Void
  private var cancelled = false
  private var pending = false
  /// Fallback registrations of the latest run, dropped when the loop goes away.
  private nonisolated let registrations = Mutex<RegistrationBag?>(nil)

  init(render: @escaping @MainActor () -> Void) {
    self.render = render
  }

  deinit {
    registrations.withLock { $0 }?.cancelAll()
  }

  func run() {
    guard !cancelled else { return }
    pending = false
    let (_, bag) = compatTrack({ render() }, onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.rerun() }
      }
    })
    registrations.withLock { $0 = bag }
  }

  private func rerun() {
    guard !cancelled, !pending else { return }
    pending = true
    run()
  }

  func cancel() {
    cancelled = true
    registrations.withLock { $0 }?.cancelAll()
  }
}

// MARK: - Small primitives

final class OnceFlag: @unchecked Sendable {
  private let state = Mutex(false)

  func claim() -> Bool {
    state.withLock { claimed in
      if claimed { return false }
      claimed = true
      return true
    }
  }

  var isClaimed: Bool { state.withLock { $0 } }
}

final class RegistrationBag: @unchecked Sendable {
  private let cancels = Mutex<[() -> Void]?>([])

  func add(_ cancel: @escaping () -> Void) {
    let runNow: Bool = cancels.withLock { list in
      guard list != nil else { return true }
      list!.append(cancel)
      return false
    }
    if runNow { cancel() }
  }

  func cancelAll() {
    let list = cancels.withLock { list -> [() -> Void] in
      defer { list = nil }
      return list ?? []
    }
    for cancel in list { cancel() }
  }
}
