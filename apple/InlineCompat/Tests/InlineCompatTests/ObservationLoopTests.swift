import Dispatch
import Foundation
@testable import InlineCompat
import Testing

/// Main-actor render log for `CompatObservation.observe`.
@MainActor
private final class RenderLog {
  var renders = 0
  var seen: [Int] = []
  var offMainRenders = 0
}

/// `CompatObservation.observe` on every registrar path.
@MainActor
@Suite("CompatObservation.observe")
struct ObservationLoopTests {
  @Test("first run is synchronous", arguments: SubjectKind.allCases)
  func firstRunIsSynchronous(_ kind: SubjectKind) {
    let subject = makeSubject(kind)
    subject.count = 7
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      log.seen.append(subject.count)
    }
    #expect(log.renders == 1)
    #expect(log.seen == [7])
    #expect(!token.isCancelled)
    token.cancel()
  }

  @Test("re-runs after a change on the next main-queue turn", arguments: SubjectKind.allCases)
  func rerunsOnNextTurn(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      log.seen.append(subject.count)
    }

    subject.count = 1
    #expect(log.renders == 1, "re-render is deferred, not synchronous")
    await drainMainQueue()
    #expect(log.renders == 2)
    #expect(log.seen == [0, 1])

    subject.count = 2
    await drainMainQueue()
    subject.count = 3
    await drainMainQueue()
    #expect(log.seen == [0, 1, 2, 3])
    withExtendedLifetime(token) {}
  }

  @Test("several synchronous mutations coalesce into one re-render", arguments: SubjectKind.allCases)
  func coalescesSynchronousMutations(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      log.seen.append(subject.count + subject.other)
    }

    subject.count = 1
    subject.other = 10
    subject.count = 2
    subject.other = 20
    await drainMainQueue(turns: 3)
    #expect(log.renders == 2)
    #expect(log.seen == [0, 22])
    withExtendedLifetime(token) {}
  }

  @Test("changes to unread or untracked properties do not re-render", arguments: SubjectKind.allCases)
  func ignoresUnreadProperties(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      _ = subject.count
      _ = subject.untracked
    }
    subject.name = "x"
    subject.other = 1
    subject.untracked = 1
    await drainMainQueue(turns: 3)
    #expect(log.renders == 1)
    withExtendedLifetime(token) {}
  }

  @Test("picks up new dependencies when the read set changes between runs", arguments: SubjectKind.allCases)
  func dynamicDependencies(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    // count == 0 reads `other`; afterwards it reads `name` instead.
    let token = CompatObservation.observe {
      log.renders += 1
      if subject.count == 0 {
        _ = subject.other
      } else {
        _ = subject.name
      }
    }

    subject.name = "not yet read"
    await drainMainQueue()
    #expect(log.renders == 1)

    subject.count = 1
    await drainMainQueue()
    #expect(log.renders == 2)

    subject.other = 5 // dropped dependency
    await drainMainQueue(turns: 2)
    #expect(log.renders == 2)

    subject.name = "now read" // new dependency
    await drainMainQueue()
    #expect(log.renders == 3)
    withExtendedLifetime(token) {}
  }

  @Test("tracks several subjects at once", arguments: SubjectKind.allCases)
  func multipleSubjects(_ kind: SubjectKind) async {
    let a = makeSubject(kind)
    let b = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      log.seen.append(a.count + b.count)
    }
    a.count = 1
    await drainMainQueue()
    b.count = 2
    await drainMainQueue()
    a.count = 3
    b.count = 4
    await drainMainQueue()
    #expect(log.seen == [0, 1, 3, 7])
    withExtendedLifetime(token) {}
  }

  @Test("render that writes what it reads does not loop", arguments: SubjectKind.allCases)
  func renderWritingItsOwnInput(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      subject.name = "\(subject.count)" // writes during render are not observed by this run
      _ = subject.name
    }
    subject.count = 1
    await drainMainQueue(turns: 4)
    #expect(log.renders == 2)
    #expect(subject.name == "1")
    withExtendedLifetime(token) {}
  }

  @Test("independent observers each re-render once", arguments: SubjectKind.allCases)
  func independentObservers(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let first = RenderLog()
    let second = RenderLog()
    let tokens = [
      CompatObservation.observe { first.renders += 1; _ = subject.count },
      CompatObservation.observe { second.renders += 1; _ = subject.count },
    ]
    subject.count = 1
    await drainMainQueue(turns: 2)
    #expect(first.renders == 2)
    #expect(second.renders == 2)
    withExtendedLifetime(tokens) {}
  }

  @Test("changes from a background thread re-render on the main thread", arguments: SubjectKind.allCases)
  func backgroundMutation(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      if !Thread.isMainThread { log.offMainRenders += 1 }
      log.seen.append(subject.count)
    }
    runOnNewThread { subject.count = 42 }
    #expect(await waitUntil { log.renders == 2 })
    #expect(log.seen == [0, 42])
    #expect(log.offMainRenders == 0)
    withExtendedLifetime(token) {}
  }

  // MARK: Cancellation and release

  @Test("cancel() stops re-renders and drops registrations", arguments: SubjectKind.allCases)
  func cancelStops(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      _ = subject.count
    }
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))

    token.cancel()
    #expect(token.isCancelled)
    #expect(subject.fallbackObserverCount == 0)

    subject.count = 1
    await drainMainQueue(turns: 3)
    #expect(log.renders == 1)

    token.cancel() // idempotent
    #expect(token.isCancelled)
  }

  @Test("cancel() after a change but before the re-render wins", arguments: SubjectKind.allCases)
  func cancelBeforePendingRerun(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      _ = subject.count
    }
    subject.count = 1 // schedules a re-render
    token.cancel()
    await drainMainQueue(turns: 3)
    #expect(log.renders == 1)
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("releasing the token stops re-renders and drops registrations", arguments: SubjectKind.allCases)
  func releaseStops(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    var token: CompatObservationToken? = CompatObservation.observe {
      log.renders += 1
      _ = subject.count
    }
    #expect(token != nil)
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))

    subject.count = 1
    await drainMainQueue()
    #expect(log.renders == 2)
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))

    token = nil
    #expect(subject.fallbackObserverCount == 0)
    subject.count = 2
    await drainMainQueue(turns: 3)
    #expect(log.renders == 2)
  }

  @Test("releasing the token while a re-render is queued drops it", arguments: SubjectKind.allCases)
  func releaseBeforePendingRerun(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    var token: CompatObservationToken? = CompatObservation.observe {
      log.renders += 1
      _ = subject.count
    }
    subject.count = 1
    token = nil
    await drainMainQueue(turns: 3)
    #expect(token == nil)
    #expect(log.renders == 1)
    #expect(subject.fallbackObserverCount == 0)
  }

  @Test("releasing the token frees the render closure", arguments: SubjectKind.allCases)
  func releaseFreesRenderClosure(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    weak var weakSentinel: Sentinel?
    var token: CompatObservationToken?
    do {
      let sentinel = Sentinel()
      weakSentinel = sentinel
      token = CompatObservation.observe {
        _ = sentinel
        _ = subject.count
      }
    }
    subject.count = 1
    await drainMainQueue()
    #expect(weakSentinel != nil)
    token = nil
    #expect(token == nil)
    #expect(weakSentinel == nil)
  }

  @Test("a subject released while observed does not leak its registrar", arguments: SubjectKind.allCases)
  func subjectReleasedWhileObserved(_ kind: SubjectKind) async {
    weak var weakSubject: AnyObject?
    weak var weakFallback: FallbackRegistrar?
    let log = RenderLog()
    var token: CompatObservationToken?
    do {
      let subject = makeSubject(kind)
      weakSubject = subject
      weakFallback = subject.observationRegistrar.fallback
      token = CompatObservation.observe { [weak subject] in
        log.renders += 1
        _ = subject?.count
      }
    }
    #expect(weakSubject == nil)
    #expect(weakFallback == nil)
    await drainMainQueue(turns: 2)
    #expect(log.renders == 1)
    token?.cancel() // safe after the subject is gone
    #expect(token?.isCancelled == true)
  }

  @Test("many change/re-render cycles stay fast and leave one registration", arguments: SubjectKind.allCases)
  func manyCycles(_ kind: SubjectKind) async {
    let subject = makeSubject(kind)
    let log = RenderLog()
    let token = CompatObservation.observe {
      log.renders += 1
      _ = subject.count
    }
    let clock = Swift.ContinuousClock()
    let elapsed = await clock.measure {
      for value in 1 ... 500 {
        subject.count = value
        await drainMainQueue()
      }
    }
    #expect(log.renders == 501)
    #expect(subject.fallbackObserverCount == kind.fallbackObservers(1))
    #expect(elapsed < .seconds(2), "500 cycles took \(elapsed)")
    withExtendedLifetime(token) {}
  }
}
