import Dispatch
import Foundation
@testable import InlineCompat
import Testing

#if canImport(Observation)
import Observation
#endif

/// `withCompatObservationTracking` on every registrar path.
@Suite("withCompatObservationTracking")
struct ObservationTrackingTests {
  // MARK: Registrar mode

  @Test("usesNativeRegistrar reflects the subject and the force flag")
  func registrarMode() {
    let native = makeSubject(.native)
    #expect(native.usesNativeRegistrar)
    let forced = makeSubject(.forcedFallback)
    #expect(!forced.usesNativeRegistrar)
    let plain = makeSubject(.plain)
    #expect(!plain.usesNativeRegistrar)
  }

  @Test("forcesFallbackForTesting applies to registrars created while it is set")
  func globalForceFallback() {
    let before = CompatObservationRegistrar.forcesFallbackForTesting
    defer { CompatObservationRegistrar.forcesFallbackForTesting = before }

    CompatObservationRegistrar.forcesFallbackForTesting = true
    let forced = ObservableSubject()
    CompatObservationRegistrar.forcesFallbackForTesting = false
    let native = ObservableSubject()

    #expect(!forced.usesNativeRegistrar)
    #expect(native.usesNativeRegistrar)

    // The forced subject still notifies through the fallback path.
    let fired = Recorder<Int>()
    withCompatObservationTracking { _ = forced.count } onChange: { fired.append(1) }
    forced.count = 1
    #expect(fired.count == 1)
  }

  // MARK: Core contract

  @Test("onChange fires exactly once, before the value changes", arguments: SubjectKind.allCases)
  func firesOnceWithWillSetSemantics(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    subject.count = 1
    let seen = Recorder<Int>()

    let result = withCompatObservationTracking {
      subject.count * 10
    } onChange: {
      seen.append(subject.count)
    }
    #expect(result == 10)
    #expect(seen.count == 0)

    subject.count = 2
    #expect(seen.values == [1], "onChange must see the old value")
    #expect(subject.count == 2)

    subject.count = 3
    subject.count = 4
    #expect(seen.values == [1], "one-shot: later changes do not fire again")
  }

  @Test("writing the same value still counts as a change", arguments: SubjectKind.allCases)
  func sameValueWrite(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    withCompatObservationTracking { _ = subject.count } onChange: { fired.append(1) }
    subject.count = subject.count
    #expect(fired.count == 1)
  }

  @Test("only properties read in apply fire", arguments: SubjectKind.allCases)
  func onlyReadPropertiesFire(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<String>()
    withCompatObservationTracking { _ = subject.count } onChange: { fired.append("count") }

    subject.name = "changed"
    subject.other = 99
    subject.untracked = 5
    subject.manual = 3
    #expect(fired.count == 0)

    subject.count = 1
    #expect(fired.values == ["count"])
  }

  @Test("untracked properties never fire and register nothing", arguments: SubjectKind.allCases)
  func untrackedNeverFires(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    let value = withCompatObservationTracking { subject.untracked + 1 } onChange: { fired.append(1) }
    #expect(value == 1)
    #expect(subject.fallbackObserverCount == 0)
    for value in 1 ... 5 { subject.untracked = value }
    #expect(fired.count == 0)
  }

  @Test("apply that reads nothing never fires", arguments: SubjectKind.allCases)
  func readNothing(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    withCompatObservationTracking { 42 } onChange: { fired.append(1) }
    subject.count = 1
    subject.name = "x"
    #expect(fired.count == 0)
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("manual access/willSet/didSet properties are tracked", arguments: SubjectKind.allCases)
  func manualProperties(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    subject.manual = 7
    let seen = Recorder<Int>()
    withCompatObservationTracking { _ = subject.manual } onChange: { seen.append(subject.manual) }
    subject.count = 1
    #expect(seen.count == 0)
    subject.manual = 8
    #expect(seen.values == [7])
    #expect(subject.manual == 8)
  }

  @Test("any read property fires, once, when several are read", arguments: SubjectKind.allCases)
  func severalPropertiesOneObserver(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    withCompatObservationTracking {
      _ = subject.count
      _ = subject.name
      _ = subject.manual
      _ = subject.count
    } onChange: {
      fired.append(1)
    }
    // One observer per registrar per scope, however many key paths were read.
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))
    subject.name = "a"
    subject.count = 1
    subject.manual = 1
    #expect(fired.count == 1)
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("multiple objects in one scope", arguments: SubjectKind.allCases)
  func multipleObjects(_ kind: SubjectKind) {
    let a = makeSubject(kind)
    let b = makeSubject(kind)
    let fired = Recorder<Int>()
    withCompatObservationTracking {
      _ = a.count
      _ = b.name
    } onChange: {
      fired.append(1)
    }
    #expect(a.fallbackObserverCount == kind.fallbackObservers(1))
    #expect(b.fallbackObserverCount == kind.fallbackObservers(1))

    b.count = 1 // not read on b
    a.name = "x" // not read on a
    #expect(fired.count == 0)

    b.name = "changed"
    #expect(fired.count == 1)
    // Firing tears down the registrations on every object in the scope.
    #expect(a.fallbackObserverCount == 0)
    #expect(b.fallbackObserverCount == 0)

    a.count = 1
    #expect(fired.count == 1)
  }

  @Test("mixing native and fallback subjects in one scope", arguments: SubjectKind.allCases)
  func mixedKindsInOneScope(_ trigger: SubjectKind) {
    let subjects = Dictionary(uniqueKeysWithValues: SubjectKind.allCases.map { ($0, makeSubject($0)) })
    let fired = Recorder<Int>()
    withCompatObservationTracking {
      for subject in subjects.values { _ = subject.count }
    } onChange: {
      fired.append(1)
    }
    subjects[trigger]!.count = 1
    #expect(fired.count == 1)
    for subject in subjects.values {
      subject.count += 1
      #expect(subject.fallbackObserverCount == 0)
    }
    #expect(fired.count == 1)
  }

  @Test("independent scopes on the same property each fire once", arguments: SubjectKind.allCases)
  func independentScopes(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    for index in 0 ..< 10 {
      withCompatObservationTracking { _ = subject.count } onChange: { fired.append(index) }
    }
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(10))
    subject.count = 1
    #expect(fired.values.sorted() == Array(0 ..< 10))
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("observers are removed after firing", arguments: SubjectKind.allCases)
  func cleanupAfterFiring(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    #expect(subject.fallbackObserverCount == 0)
    withCompatObservationTracking { _ = subject.count } onChange: {}
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))
    subject.count = 1
    #expect(subject.fallbackObserverCount == 0)

    // Reading inside onChange (outside any scope) registers nothing new.
    withCompatObservationTracking { _ = subject.count } onChange: { _ = subject.count }
    subject.count = 2
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("mutating inside apply does not fire; a later change does", arguments: SubjectKind.allCases)
  func mutationInsideApply(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    withCompatObservationTracking {
      _ = subject.count
      subject.count = 5
    } onChange: {
      fired.append(subject.count)
    }
    #expect(fired.count == 0)
    subject.count = 6
    #expect(fired.values == [5])
  }

  @Test("re-subscribing from onChange follows every change", arguments: SubjectKind.allCases)
  func resubscribeFromOnChange(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let seen = Recorder<Int>()

    @Sendable func track() {
      withCompatObservationTracking { _ = subject.count } onChange: {
        seen.append(subject.count)
        track()
      }
    }
    track()
    for value in 1 ... 5 { subject.count = value }
    #expect(seen.values == [0, 1, 2, 3, 4], "each mutation notifies exactly once")
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))
  }

  // MARK: Nesting

  @Test("nested scopes report their own reads to their own onChange", arguments: SubjectKind.allCases)
  func nestedScopesFireIndependently(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let outer = Recorder<Int>()
    let inner = Recorder<Int>()
    withCompatObservationTracking {
      _ = subject.count
      withCompatObservationTracking { _ = subject.name } onChange: { inner.append(1) }
      _ = subject.other
    } onChange: {
      outer.append(1)
    }

    subject.other = 1
    #expect(outer.count == 1, "reads after the nested scope still belong to the outer one")
    #expect(inner.count == 0)

    subject.name = "inner"
    #expect(inner.count == 1)
    #expect(outer.count == 1)
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("nested scope reads also reach the outer scope, like native withObservationTracking", arguments: SubjectKind.allCases)
  func nestedScopeReadsPropagateOutward(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let outer = Recorder<Int>()
    let inner = Recorder<Int>()
    withCompatObservationTracking {
      _ = subject.count
      withCompatObservationTracking { _ = subject.name } onChange: { inner.append(1) }
    } onChange: {
      outer.append(1)
    }
    // Native Observation merges a nested scope's accesses into the enclosing scope, so a
    // change to `name` must reach both, on every path.
    subject.name = "x"
    #expect(inner.count == 1)
    #expect(outer.count == 1)
  }

  @Test("a nested scope does not see reads made by the outer scope", arguments: SubjectKind.allCases)
  func outerReadsStayOutOfInner(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let outer = Recorder<Int>()
    let inner = Recorder<Int>()
    withCompatObservationTracking {
      _ = subject.count
      withCompatObservationTracking { _ = subject.name } onChange: { inner.append(1) }
    } onChange: {
      outer.append(1)
    }
    subject.count = 1
    #expect(outer.count == 1)
    #expect(inner.count == 0)
  }

  // MARK: Threads

  @Test("changes from another thread fire on that thread", arguments: SubjectKind.allCases)
  func changeFromAnotherThread(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let firedOnMutatingThread = Recorder<Bool>()
    let mutatingThread = Mutex<Thread?>(nil)
    withCompatObservationTracking { _ = subject.count } onChange: {
      firedOnMutatingThread.append(Thread.current == mutatingThread.withLock { $0 })
    }
    runOnNewThread {
      mutatingThread.withLock { $0 = Thread.current }
      subject.count = 1
    }
    #expect(firedOnMutatingThread.values == [true])
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("tracking set up on another thread fires for changes here", arguments: SubjectKind.allCases)
  func trackOnAnotherThread(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    runOnNewThread {
      withCompatObservationTracking { _ = subject.name } onChange: { fired.append(1) }
    }
    subject.name = "x"
    #expect(fired.count == 1)
  }

  @Test("reads on other threads do not leak into a scope", arguments: SubjectKind.allCases)
  func scopesAreThreadLocal(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    let inside = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)

    Thread {
      withCompatObservationTracking {
        _ = subject.count
        inside.signal()
        resume.wait()
      } onChange: {
        fired.append(1)
      }
      done.signal()
    }.start()

    inside.wait()
    _ = subject.name // read here while the other thread's scope is open
    resume.signal()
    done.wait()

    subject.name = "x"
    #expect(fired.count == 0)
    subject.count = 1
    #expect(fired.count == 1)
  }

  @Test("many concurrent scopes all fire exactly once", arguments: SubjectKind.allCases)
  func concurrentScopes(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    DispatchQueue.concurrentPerform(iterations: 50) { index in
      withCompatObservationTracking { _ = subject.count } onChange: { fired.append(index) }
    }
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(50))
    subject.count = 1
    #expect(fired.values.sorted() == Array(0 ..< 50))
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("concurrent writers fire each scope once", arguments: SubjectKind.allCases)
  func concurrentWriters(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let fired = Recorder<Int>()
    for index in 0 ..< 20 {
      withCompatObservationTracking { _ = subject.manual } onChange: { fired.append(index) }
    }
    // `manual` writes are unsynchronised in the fixture; serialise them with a lock but run
    // them from many threads so willSet races on the registrar.
    let writeLock = Mutex(())
    DispatchQueue.concurrentPerform(iterations: 8) { value in
      writeLock.withLock { _ in subject.manual = value }
    }
    #expect(fired.values.sorted() == Array(0 ..< 20))
    #expect(subject.fallbackObserverCount == 0)
  }

  // MARK: Lifetime

  @Test("releasing a subject frees its registrar and pending handlers", arguments: SubjectKind.allCases)
  func releasingSubjectFreesHandlers(_ kind: SubjectKind) {
    weak var weakSubject: AnyObject?
    weak var weakFallback: FallbackRegistrar?
    weak var weakSentinel: Sentinel?
    do {
      let subject = makeSubject(kind)
      let sentinel = Sentinel()
      weakSubject = subject
      weakFallback = subject.observationRegistrar.fallback
      weakSentinel = sentinel
      withCompatObservationTracking { _ = subject.count } onChange: { _ = sentinel }
      #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))
    }
    #expect(weakSubject == nil)
    #expect(weakFallback == nil, "the fallback registrar must not keep itself alive")
    #expect(weakSentinel == nil, "a handler that never fired must be released with its subject")
  }

  @Test("the handler is released once it has fired", arguments: SubjectKind.allCases)
  func handlerReleasedAfterFiring(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    weak var weakSentinel: Sentinel?
    do {
      let sentinel = Sentinel()
      weakSentinel = sentinel
      withCompatObservationTracking { _ = subject.count } onChange: { _ = sentinel }
    }
    #expect(weakSentinel != nil, "a pending handler is kept alive")
    subject.count = 1
    #expect(weakSentinel == nil)
  }

  @Test("tracking does not retain the subject", arguments: SubjectKind.allCases)
  func trackingDoesNotRetainSubject(_ kind: SubjectKind) {
    weak var weakSubject: AnyObject?
    let fired = Recorder<Int>()
    do {
      let subject = makeSubject(kind)
      weakSubject = subject
      withCompatObservationTracking { _ = subject.count } onChange: { fired.append(1) }
    }
    #expect(weakSubject == nil)
    #expect(fired.count == 0)
  }

  // MARK: Main-actor models

  @MainActor
  @Test("main-actor models work with @Tracked and private(set)")
  func mainActorModel() {
    let model = MainActorModel()
    let seen = Recorder<[Int]>()
    withCompatObservationTracking { _ = model.items } onChange: {
      MainActor.assumeIsolated { seen.append(model.items) }
    }
    model.title = "b"
    #expect(seen.count == 0)
    model.append(1)
    #expect(seen.values == [[]])
    #expect(model.items == [1])
  }

  // MARK: Performance

  @Test("100k tracked reads and writes are fast", arguments: SubjectKind.allCases)
  func performance(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    let clock = Swift.ContinuousClock()
    var sum = 0

    let untrackedScope = clock.measure {
      for value in 0 ..< 100_000 {
        subject.count = value
        sum &+= subject.count
      }
    }

    let inScope = clock.measure {
      withCompatObservationTracking {
        for _ in 0 ..< 100_000 { sum &+= subject.count }
      } onChange: {}
      for value in 0 ..< 100_000 { subject.count = value }
    }

    #expect(sum != 42)
    #expect(subject.fallbackObserverCount == 0)
    #expect(untrackedScope < .seconds(1), "100k reads+writes took \(untrackedScope)")
    #expect(inScope < .seconds(1), "100k tracked reads + 100k writes took \(inScope)")
  }
}

// MARK: - Native interop

#if canImport(Observation)
@Suite("Native Observation interop")
struct NativeObservationInteropTests {
  @Test("Apple's withObservationTracking sees @Tracked reads and fires once before the change")
  func appleTrackingFiresOnce() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let subject = ObservableSubject(forceFallback: false)
    subject.count = 1
    let seen = Recorder<Int>()
    let result = withObservationTracking {
      subject.count + 1
    } onChange: {
      seen.append(subject.count)
    }
    #expect(result == 2)
    subject.name = "unread"
    subject.untracked = 1
    #expect(seen.count == 0)
    subject.count = 2
    subject.count = 3
    #expect(seen.values == [1])
  }

  @Test("Apple's withObservationTracking sees manual access/willSet/didSet")
  func appleTrackingManual() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let subject = ObservableSubject(forceFallback: false)
    let fired = Recorder<Int>()
    withObservationTracking { _ = subject.manual } onChange: { fired.append(1) }
    subject.manual = 1
    #expect(fired.count == 1)
  }

  @Test("Apple's withObservationTracking ignores a subject whose registrar is forced onto the fallback")
  func appleTrackingIgnoresForcedFallback() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let subject = ObservableSubject(forceFallback: true)
    let fired = Recorder<Int>()
    withObservationTracking { _ = subject.count } onChange: { fired.append(1) }
    subject.count = 1
    #expect(fired.count == 0)
  }

  @Test("Apple's and compat tracking can observe the same subject together")
  func appleAndCompatTogether() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let subject = ObservableSubject(forceFallback: false)
    let apple = Recorder<Int>()
    let compat = Recorder<Int>()
    withObservationTracking { _ = subject.count } onChange: { apple.append(subject.count) }
    withCompatObservationTracking { _ = subject.count } onChange: { compat.append(subject.count) }
    subject.count = 9
    #expect(apple.values == [0])
    #expect(compat.values == [0])
  }

  @Test("compat tracking nested in Apple's tracking reports reads to both")
  func compatInsideApple() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let subject = ObservableSubject(forceFallback: false)
    let apple = Recorder<Int>()
    let compat = Recorder<Int>()
    withObservationTracking {
      withCompatObservationTracking { _ = subject.name } onChange: { compat.append(1) }
    } onChange: {
      apple.append(1)
    }
    subject.name = "x"
    #expect(compat.count == 1)
    #expect(apple.count == 1)
  }

  @Test("native nesting merges inner reads into the outer scope (reference behaviour)")
  func nativeNestingReference() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let subject = ObservableSubject(forceFallback: false)
    let outer = Recorder<Int>()
    let inner = Recorder<Int>()
    withObservationTracking {
      _ = subject.count
      withObservationTracking { _ = subject.name } onChange: { inner.append(1) }
    } onChange: {
      outer.append(1)
    }
    subject.name = "x"
    #expect(inner.count == 1)
    #expect(outer.count == 1)
  }

  @MainActor
  @Test("main-actor model works with Apple's tracking")
  func mainActorModelNative() {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let model = MainActorModel()
    #expect(model.observationRegistrar.usesNativeRegistrar(for: model))
    let fired = Recorder<Int>()
    withObservationTracking { _ = model.title } onChange: { fired.append(1) }
    model.title = "z"
    #expect(fired.count == 1)
  }
}
#endif
