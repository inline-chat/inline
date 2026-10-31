import Foundation
@testable import ChatListCore
import Testing

@MainActor
struct ChatListSessionTests {
  private typealias Session = ChatListSession<Int, String>
  private typealias Snapshot = ChatListSnapshot<Int, String>
  private let viewport = TimelineViewport(width: 600, height: 500, topInset: 40, bottomInset: 60)

  private func snapshot(
    _ ids: [Int] = Array(0 ..< 30), context: ChatListLayoutContext = .init(width: 600),
    revision: UInt64 = 0, height: CGFloat = 40, history: ChatListHistoryAvailability = .init()
  ) -> Snapshot {
    .init(
      context: context,
      items: ids.map { .init(id: $0, revision: revision, content: "\($0):\(revision)", height: height) },
      history: history
    )
  }

  private func session() -> Session { Session(viewport: viewport, now: { 0 }) }

  @Test func `invalid snapshots cannot mutate installed presentation or emit a frame`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    let origin = session.timeline.layout.originY
    let frames = session.timeline.layout.rows.map(\.frame)
    var presentations = 0
    session.onPresentationChanged = { presentations += 1 }

    let invalid: [(Snapshot, ChatListError)] = [
      (snapshot([1, 1]), .duplicateIdentity),
      (snapshot(height: -.infinity), .invalidGeometry),
      (snapshot(height: .nan), .invalidGeometry),
      (snapshot(context: .init(width: 0)), .invalidContext),
      (snapshot(context: .init(width: .nan)), .invalidContext),
      (snapshot(context: .init(width: 600, displayScale: 0)), .invalidContext),
      (snapshot(context: .init(width: 600, displayScale: .infinity)), .invalidContext),
      (
        .init(context: .init(width: 600), items: [
          .init(id: 1, revision: 0, content: "bad child", height: 100,
                elements: ["child": CGRect(x: 0, y: CGFloat.nan, width: 10, height: 20)])
        ]), .invalidGeometry
      )
    ]
    for (candidate, error) in invalid {
      #expect(throws: error) { try session.apply(candidate, animation: .none, at: 1) }
      #expect(session.generation == 1)
      #expect(session.timeline.layout.originY == origin)
      #expect(session.timeline.layout.rows.map(\.frame) == frames)
    }
    #expect(presentations == 0)
  }

  @Test func `binding context fences width scale and external layout revision independently`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    for context in [
      ChatListLayoutContext(width: 601),
      ChatListLayoutContext(width: 600, displayScale: 2),
      ChatListLayoutContext(width: 600, environmentRevision: 1)
    ] {
      #expect(throws: ChatListError.staleContext) {
        try session.apply(snapshot(context: context), animation: .none, at: 1)
      }
    }
    #expect(session.generation == 1)
    #expect(session.snapshot?.context == .init(width: 600))
  }

  @Test func `first frame is exact for short bottom alignment and explicit reading intent`() throws {
    let short = session()
    var observedBottoms: [CGFloat] = []
    short.onPresentationChanged = {
      if let row = short.timeline.layout.rows.last { observedBottoms.append(row.frame.maxY) }
    }
    try short.apply(snapshot([1, 2]), animation: .animated, at: 0)
    #expect(observedBottoms == [viewport.height - viewport.bottomInset])
    #expect(short.timeline.layout.originY == 0)
    #expect(!short.timeline.isAnimating)

    let reader = session()
    let anchor = TimelineAnchor(id: 15, localY: 13, viewportY: 27)
    try reader.apply(snapshot(), intent: .reading(anchor), animation: .animated, at: 0)
    let row = try #require(reader.timeline.layout.placement(for: 15))
    #expect(abs(row.frame.minY + 13 - reader.timeline.layout.readingRect.minY - 27) < 0.001)
    #expect(reader.timeline.intent == .reading(anchor))
    #expect(!reader.timeline.isAnimating)
  }

  @Test func `initial reading point stays locked through idle publications until actual native movement`() throws {
    let session = session()
    defer { session.dispose() }
    func content(_ ids: Range<Int>, revision: UInt64) -> Snapshot {
      .init(context: .init(width: 600), items: ids.map { id in
        let height: CGFloat = id == 40 ? 1_200 : (id == 10 || id == 60 ? 40 + CGFloat(revision) * 31 : 40)
        return .init(id: id, revision: revision, content: "\(id):\(revision)", height: height)
      }, history: .init(hasOlder: true, hasNewer: true, isAtLiveEnd: false))
    }
    let initial = TimelineAnchor(id: 40, localY: 480, viewportY: 90)
    var observedOrigins: [CGFloat] = []
    session.onPresentationChanged = { observedOrigins.append(session.timeline.layout.originY) }
    try session.apply(content(0 ..< 80, revision: 0), intent: .reading(initial), animation: .animated, at: 0)
    let firstRow = try #require(session.timeline.layout.placement(for: 40))
    #expect(observedOrigins == [firstRow.frame.minY + 480 - viewport.topInset - 90])
    #expect(!session.timeline.isAnimating)
    var time = 0.0
    for revision in 1 ... 8 {
      try session.apply(content((-revision) ..< (80 + revision), revision: UInt64(revision)),
                        animation: .animated, at: time)
      for _ in 0 ..< 12 {
        time += 1.0 / 120
        session.advance(to: time)
        session.didPresent()
        let row = try #require(session.timeline.layout.placement(for: 40))
        #expect(session.timeline.intent == .reading(initial))
        #expect(abs(row.frame.minY + 480 - session.timeline.layout.readingRect.minY - 90) < 0.001)
      }
    }
    session.advance(to: time + 2)
    time += 2
    let movedOrigin = session.timeline.layout.originY + 73
    session.beginUserScroll(at: session.timeline.layout.originY)
    session.userScrolled(to: movedOrigin)
    session.endUserScroll(at: movedOrigin, time: time)
    guard case let .reading(moved) = session.timeline.intent else {
      Issue.record("Actual native movement lost reading intent")
      return
    }
    #expect(moved != initial)
    #expect(abs(session.timeline.layout.originY - movedOrigin) < 0.001)
    try session.apply(content(-20 ..< 100, revision: 20), animation: .animated, at: time)
    for frame in 0 ... 240 {
      session.advance(to: time + Double(frame) / 120)
      let row = try #require(session.timeline.layout.placement(for: moved.id))
      #expect(session.timeline.intent == .reading(moved))
      #expect(abs(row.frame.minY + moved.localY - session.timeline.layout.readingRect.minY - moved.viewportY) < 0.001)
    }
  }

  @Test(arguments: [false, true])
  func `portrait landscape and return preserve cell semantic point with atomic or withheld width preparation`(
    withholdPreparation: Bool
  ) async throws {
    final class Host {}
    @MainActor final class Clock { var time = 0.0 }
    let portrait = TimelineViewport(width: 390, height: 844, topInset: 59, bottomInset: 34)
    let landscape = TimelineViewport(width: 844, height: 390, topInset: 24, bottomInset: 21)
    let clock = Clock()
    let session = Session(viewport: portrait, now: { clock.time })
    defer { session.dispose() }
    let owner = Host()
    let semanticOffset: CGFloat = 700
    let bottomDistance: CGFloat = 72
    func prepared(_ context: ChatListLayoutContext) -> Snapshot {
      .init(context: context, items: (0 ..< 80).map { id in
        .init(id: id, revision: UInt64(context.width), content: "\(id) at \(context.width)",
              height: id == 40 ? 4_000 : (context.width < 500 ? 100 : 60),
              elements: id == 40 ? ["passage": CGRect(x: 10, y: context.width < 500 ? 300 : 600,
                                                       width: context.width - 20, height: 3_000)] : [:])
      }, history: .init(hasOlder: true, hasNewer: true, isAtLiveEnd: false))
    }
    var presentations: [(CGFloat, CGFloat)] = []
    // The cell owns this opaque passage address; the list owns its geometric
    // projection. Exercise the same host callback order as a native renderer.
    session.attachHost(owner: owner, willApply: { _ in }, presentationChanged: {
      guard session.snapshot != nil else { return }
      let refined = session.refineAnchor(row: 40, location: .init(element: "passage", offsetY: semanticOffset),
                                         viewportY: bottomDistance, edge: .bottom)
      #expect(refined)
    })
    session.onPresentationChanged = {
      guard let snapshot = session.snapshot,
            let row = session.timeline.layout.placement(for: 40),
            let passage = row.row.elements["passage"] else {
        Issue.record("Presented a rotation frame without its installed semantic geometry")
        return
      }
      let layout = session.timeline.layout
      presentations.append((snapshot.context.width, layout.viewport.width))
      #expect(layout.rows.allSatisfy { $0.frame.width == snapshot.context.width })
      #expect(abs(row.frame.minY + passage.minY + semanticOffset + bottomDistance - layout.readingRect.maxY) < 0.001)
      #expect(layout.originY > 0 && layout.originY < layout.maximumOrigin)
    }
    let initialContext = ChatListLayoutContext(width: portrait.width, displayScale: 2)
    try session.apply(prepared(initialContext),
                      intent: .reading(.init(id: 40, localY: 1_000, viewportY: bottomDistance, edge: .bottom)),
                      animation: .animated, at: clock.time, viewport: portrait)
    #expect(presentations.count == 1)
    for target in [landscape, portrait] {
      let priorWidth = try #require(session.snapshot?.context.width)
      let priorViewport = session.timeline.layout.viewport
      let nextContext = ChatListLayoutContext(width: target.width, displayScale: 2)
      if withholdPreparation {
        session.updateViewport(target, displayScale: 2, animation: .animated, at: clock.time)
        let gate = ControlledPreparation()
        session.requestPreparation(identities: Array(0 ..< 80), animation: .animated, prepare: gate.prepare)
        await gate.waitUntilStarted()
        for _ in 0 ..< 36 {
          clock.time += 1.0 / 120
          session.advance(to: clock.time)
          #expect(session.layoutContext == nextContext)
          #expect(session.snapshot?.context.width == priorWidth)
          #expect(session.timeline.layout.rows.allSatisfy { $0.frame.width == priorWidth })
          #expect(session.timeline.layout.viewport.height == target.height)
          let currentViewport = session.timeline.layout.viewport
          let topProgress = (currentViewport.topInset - priorViewport.topInset) / (target.topInset - priorViewport.topInset)
          let bottomProgress = (currentViewport.bottomInset - priorViewport.bottomInset) / (target.bottomInset - priorViewport.bottomInset)
          #expect(abs(topProgress - bottomProgress) < 0.001)
        }
        let atCommit = session.timeline.layout.viewport
        let beforeCommitCount = presentations.count
        gate.succeed(prepared(nextContext))
        await drainReadyTasks()
        #expect(presentations.count == beforeCommitCount + 1)
        #expect(session.timeline.layout.viewport.topInset == atCommit.topInset)
        #expect(session.timeline.layout.viewport.bottomInset == atCommit.bottomInset)
        #expect(session.timeline.isAnimating)
      } else {
        let count = presentations.count
        try session.apply(prepared(nextContext), animation: .animated, at: clock.time, viewport: target)
        #expect(presentations.count == count + 1)
        #expect(session.timeline.layout.viewport == target)
        #expect(!session.timeline.isAnimating)
      }
      #expect(session.snapshot?.context == nextContext)
      #expect(session.timeline.layout.viewport.width == target.width)
      #expect(session.timeline.layout.viewport.height == target.height)
      #expect(session.timeline.intent != .latest)
      // Exact prepared rows arrive independently of the compositor's remaining
      // inset motion; the width commit must not snap that shared animation.
      for _ in 0 ..< 120 {
        clock.time += 1.0 / 120
        session.advance(to: clock.time)
        let presentedViewport = session.timeline.layout.viewport
        let topProgress = (presentedViewport.topInset - priorViewport.topInset) / (target.topInset - priorViewport.topInset)
        let bottomProgress = (presentedViewport.bottomInset - priorViewport.bottomInset) / (target.bottomInset - priorViewport.bottomInset)
        #expect(abs(topProgress - bottomProgress) < 0.001)
      }
      #expect(session.timeline.layout.viewport == target)
      #expect(!session.timeline.isAnimating)
    }
    #expect(presentations.allSatisfy { $0.0 == $0.1 })
  }

  @Test func `width preparation holds old exact canvas while height and occlusions advance`() throws {
    let session = session()
    try session.apply(snapshot(), intent: .reading(.init(id: 15, localY: 7)), animation: .none, at: 0)
    let bottom = try #require(session.timeline.layout.anchor(edge: .bottom))
    var demands: [ChatListLayoutContext] = []
    session.onNeedsSnapshot = { demands.append($0) }
    let narrow = TimelineViewport(width: 320, height: 400, topInset: 80, bottomInset: 90)
    session.updateViewport(narrow, displayScale: 2, environmentRevision: 4, animation: .none, at: 1)

    #expect(session.layoutContext == .init(width: 320, displayScale: 2, environmentRevision: 4))
    #expect(session.timeline.layout.viewport.width == 600)
    #expect(session.timeline.layout.viewport.height == 400)
    #expect(session.timeline.layout.rows.allSatisfy { $0.frame.width == 600 })
    #expect(demands == [session.layoutContext])
    #expect(throws: ChatListError.staleContext) { try session.apply(snapshot(), at: 1) }

    try session.apply(snapshot(context: session.layoutContext, height: 75), animation: .animated, at: 1)
    let anchor = try #require(session.timeline.layout.placement(for: bottom.id))
    #expect(session.timeline.layout.viewport == narrow)
    #expect(session.timeline.layout.rows.allSatisfy { $0.frame.width == 320 && $0.frame.height == 75 })
    #expect(abs(anchor.frame.minY + bottom.localY + bottom.viewportY - session.timeline.layout.readingRect.maxY) < 0.001)
    #expect(!session.timeline.isAnimating)
  }

  @Test func `snapshot and viewport install as one observable transaction`() throws {
    let session = session()
    try session.apply(snapshot(), intent: .reading(.init(id: 15, localY: 8)), animation: .none, at: 0)
    let bottom = try #require(session.timeline.layout.anchor(edge: .bottom))
    let nextViewport = TimelineViewport(width: 300, height: 410, topInset: 75, bottomInset: 100)
    let next = snapshot(context: .init(width: 300, displayScale: 2, environmentRevision: 9), height: 80)
    var frames: [(ChatListLayoutContext?, TimelineViewport, CGFloat)] = []
    session.onPresentationChanged = {
      frames.append((session.snapshot?.context, session.timeline.layout.viewport, session.timeline.layout.originY))
    }
    try session.apply(next, animation: .none, at: 1, viewport: nextViewport)
    #expect(frames.count == 1)
    #expect(frames.first?.0 == next.context)
    #expect(frames.first?.1 == nextViewport)
    #expect(session.layoutContext == next.context)
    let row = try #require(session.timeline.layout.placement(for: bottom.id))
    #expect(abs(row.frame.minY + bottom.localY + bottom.viewportY - session.timeline.layout.readingRect.maxY) < 0.001)
  }

  @Test func `invalid atomic transaction leaves requested context unchanged`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    let oldContext = session.layoutContext
    #expect(throws: ChatListError.duplicateIdentity) {
      try session.apply(snapshot([1, 1], context: .init(width: 300)), at: 1,
                        viewport: .init(width: 300, height: 400))
    }
    #expect(session.layoutContext == oldContext)
    #expect(session.timeline.layout.viewport == viewport)
    #expect(session.generation == 1)
  }

  @Test func `host callbacks coexist with consumer callbacks and detach only matching owner`() throws {
    final class Owner {}
    let session = session()
    let host = Owner()
    let other = Owner()
    var calls: [String] = []
    session.onWillApply = { _ in calls.append("consumer capture") }
    session.onPresentationChanged = { calls.append("consumer present") }
    session.attachHost(owner: host, willApply: { _ in calls.append("host capture") },
                       presentationChanged: { calls.append("host present") })
    session.detachHost(owner: other)
    try session.apply(snapshot(), animation: .none, at: 0)
    #expect(calls.filter { $0 == "consumer capture" }.count == 1)
    #expect(calls.filter { $0 == "host capture" }.count == 1)
    #expect(calls.filter { $0 == "consumer present" }.count == 1)
    #expect(calls.filter { $0 == "host present" }.count == 1)
    #expect(try #require(calls.firstIndex(of: "host capture")) < #require(calls.firstIndex(of: "host present")))
    calls.removeAll()
    session.detachHost(owner: host)
    #expect(calls == ["host present"]) // Revocation lets the former host stop its clock.
    calls.removeAll()
    try session.apply(snapshot(revision: 1), animation: .none, at: 1)
    #expect(calls == ["consumer capture", "consumer present"])
  }

  @Test func `presentation is emitted only after host confirms actual installation`() throws {
    let session = session()
    var published: [UInt64] = []
    session.onPresentation = { published.append($0.generation) }
    try session.apply(snapshot(), animation: .none, at: 0)
    #expect(published.isEmpty)
    session.didPresent()
    #expect(published == [1])
  }

  @Test func `reentrant snapshot submission is rejected before replacing outer transaction`() throws {
    let session = session()
    session.onWillApply = { _ in
      #expect(throws: ChatListError.reentrantTransaction) {
        try session.apply(self.snapshot([900]), animation: .none, at: 0)
      }
    }
    try session.apply(snapshot([1, 2]), animation: .none, at: 0)
    #expect(session.snapshot?.items.map(\.id) == [1, 2])
    #expect(session.generation == 1)
  }

  @Test func `compatible preparations commit active then newest pending without starvation`() async throws {
    let session = session()
    let gate = ControlledPreparation()
    var started: [Int] = []
    var installed: [UInt64] = []
    session.onPresentationChanged = {
      if let revision = session.snapshot?.items.first?.revision { installed.append(revision) }
    }
    session.requestPreparation(identities: [1], animation: .none) { context in
      started.append(1)
      return try await gate.prepare(context)
    }
    await gate.waitUntilStarted()
    for revision in 2 ... 100 {
      session.requestPreparation(identities: [1], animation: .none) { context in
        started.append(revision)
        return self.snapshot([1], context: context, revision: UInt64(revision))
      }
    }
    gate.succeed(snapshot([1], revision: 1))
    await drainReadyTasks()
    #expect(started == [1, 100])
    #expect(installed == [1, 100])
    #expect(session.generation == 2)
  }

  @Test func `failed active preparation reports error and still promotes newest pending`() async throws {
    let session = session()
    let gate = ControlledPreparation()
    var failures = 0
    session.onPreparationError = { error in
      #expect(error is PreparationFailure)
      failures += 1
    }
    session.requestPreparation(identities: [1], animation: .none, prepare: gate.prepare)
    await gate.waitUntilStarted()
    session.requestPreparation(identities: [1], animation: .none) { context in
      self.snapshot([1], context: context, revision: 2)
    }
    gate.fail(PreparationFailure.expected)
    await drainReadyTasks()
    #expect(failures == 1)
    #expect(session.snapshot?.items.first?.revision == 2)
    #expect(session.generation == 1)
  }

  @Test func `invalid completed geometry reports error without losing pending preparation`() async throws {
    let session = session()
    let gate = ControlledPreparation()
    var failures: [ChatListError] = []
    session.onPreparationError = { if let error = $0 as? ChatListError { failures.append(error) } }
    session.requestPreparation(identities: [1], animation: .none, prepare: gate.prepare)
    await gate.waitUntilStarted()
    session.requestPreparation(identities: [1], animation: .none) { context in
      self.snapshot([1], context: context, revision: 2)
    }
    gate.succeed(snapshot([1], height: .nan))
    await drainReadyTasks()
    #expect(failures == [.invalidGeometry])
    #expect(session.snapshot?.items.first?.revision == 2)
    #expect(session.generation == 1)
  }

  @Test func `direct snapshot install fences late asynchronous prepared content`() async throws {
    let session = session()
    let gate = ControlledPreparation()
    session.requestPreparation(identities: [1], animation: .none, prepare: gate.prepare)
    await gate.waitUntilStarted()
    try session.apply(snapshot([1], revision: 99), animation: .none, at: 0)
    gate.succeed(snapshot([1], revision: 1))
    await drainReadyTasks()
    #expect(session.snapshot?.items.first?.revision == 99)
    #expect(session.generation == 1)
  }

  @Test func `changed identity order replaces preparation and fences its late completion`() async throws {
    let session = session()
    let old = ControlledPreparation()
    let replacement = ControlledPreparation()
    session.requestPreparation(identities: [1, 2], animation: .none, prepare: old.prepare)
    await old.waitUntilStarted()
    session.requestPreparation(identities: [2, 1], animation: .none, prepare: replacement.prepare)
    await replacement.waitUntilStarted()
    old.succeed(snapshot([1, 2], revision: 1))
    replacement.succeed(snapshot([2, 1], revision: 2))
    await drainReadyTasks()
    #expect(session.snapshot?.items.map(\.id) == [2, 1])
    #expect(session.generation == 1)
  }

  @Test func `superseding correction fences active and pending payloads with unchanged identities`() async throws {
    let session = session()
    defer { session.dispose() }
    let old = ControlledPreparation()
    let correction = ControlledPreparation()
    var committedRevisions: [UInt64] = []
    var stalePendingCalls = 0
    session.onPresentationChanged = {
      if let revision = session.snapshot?.items.first?.revision { committedRevisions.append(revision) }
    }
    session.requestPreparation(identities: [1], animation: .none, prepare: old.prepare)
    await old.waitUntilStarted()
    session.requestPreparation(identities: [1], animation: .none) { context in
      stalePendingCalls += 1
      return self.snapshot([1], context: context, revision: 2)
    }
    session.requestPreparation(identities: [1], animation: .none,
                               superseding: true, prepare: correction.prepare)
    await correction.waitUntilStarted()
    old.succeed(snapshot([1], revision: 1))
    await drainReadyTasks()
    #expect(session.snapshot == nil)
    #expect(committedRevisions.isEmpty)
    #expect(stalePendingCalls == 0)
    correction.succeed(snapshot([1], revision: 3))
    await drainReadyTasks()
    #expect(committedRevisions == [3])
    #expect(session.snapshot?.items.first?.revision == 3)
    #expect(stalePendingCalls == 0)
    #expect(session.generation == 1)
  }

  @Test func `user input revokes prepared navigation while compatible new content still commits`() async throws {
    let session = session()
    try session.apply(snapshot(), intent: .reading(.init(id: 15)), animation: .none, at: 0)
    let gate = ControlledPreparation()
    session.requestPreparation(identities: Array(0 ..< 30), intent: .latest,
                               animation: .none, prepare: gate.prepare)
    await gate.waitUntilStarted()
    let origin = session.timeline.layout.originY - 27
    session.beginUserScroll(at: origin)
    session.userScrolled(to: origin)
    gate.succeed(snapshot(revision: 1))
    await drainReadyTasks()
    #expect(session.snapshot?.items.first?.revision == 1)
    #expect(session.timeline.intent != .latest)
    #expect(abs(session.timeline.layout.originY - origin) < 0.001)
    #expect(session.isUserScrolling)
  }

  @Test func `native bounce defers newest content and navigation until legal settlement`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    session.beginUserScroll(at: -30)
    session.userScrolled(to: -30)
    let first = try session.apply(snapshot(revision: 1), animation: .none, at: 1)
    let second = try session.apply(snapshot(revision: 2), animation: .none, at: 1)
    session.navigate(to: .reading(.init(id: 20, localY: 7)), animation: .none, at: 1)
    #expect(first == .deferred)
    #expect(second == .deferred)
    #expect(session.snapshot?.items.first?.revision == 0)
    #expect(session.timeline.layout.originY == -30)
    var settlements: [(UInt64, TimelineIntent<Int>)] = []
    session.onPresentationChanged = { settlements.append((session.generation, session.timeline.intent)) }
    session.advance(to: 10)
    #expect(session.timeline.layout.originY == -30)
    session.endUserScroll(at: -5, time: 10)
    #expect(session.generation == 1)
    session.endUserScroll(at: 0, time: 11)
    #expect(session.snapshot?.items.first?.revision == 2)
    #expect(session.timeline.intent == .reading(.init(id: 20, localY: 7)))
    #expect(session.generation == 2)
    #expect(!session.isUserScrolling)
    #expect(settlements.count == 1)
    #expect(settlements.first?.0 == 2)
    #expect(settlements.first?.1 == .reading(.init(id: 20, localY: 7)))
  }

  @Test(arguments: [false, true])
  func `live occlusions follow interactive changes during native bounce while content and navigation wait`(
    bouncingAtBottom: Bool
  ) throws {
    let session = session()
    defer { session.dispose() }
    let history = ChatListHistoryAvailability(hasOlder: true, hasNewer: true, isAtLiveEnd: false)
    try session.apply(snapshot(history: history), animation: .none, at: 0)
    func bouncedOrigin(_ distance: CGFloat) -> CGFloat {
      bouncingAtBottom ? session.timeline.layout.maximumOrigin + distance : -distance
    }
    session.beginUserScroll(at: bouncedOrigin(27))
    session.userScrolled(to: bouncedOrigin(27))
    let deferred = try session.apply(snapshot(revision: 1, height: 70, history: history), animation: .none, at: 0)
    #expect(deferred == .deferred)
    let requested = TimelineIntent<Int>.reading(.init(id: 15, localY: 7, viewportY: 13))
    session.navigate(to: requested, animation: .none, at: 0)
    var publishedViewports: [TimelineViewport] = []
    session.onPresentationChanged = { publishedViewports.append(session.timeline.layout.viewport) }

    for (index, values) in [
      (top: CGFloat(85), bottom: CGFloat(230), height: CGFloat(470)),
      (top: CGFloat(25), bottom: CGFloat(15), height: CGFloat(540))
    ].enumerated() {
      let distance: CGFloat = index == 0 ? 27 : 11
      if index > 0 {
        session.userScrolled(to: bouncedOrigin(distance))
        #expect(abs(session.timeline.layout.originY - bouncedOrigin(distance)) < 0.001)
      }
      let beforeCount = publishedViewports.count
      let target = TimelineViewport(width: viewport.width, height: values.height,
                                    topInset: values.top, bottomInset: values.bottom)
      session.updateViewport(target, animation: .none, at: Double(index + 1))
      #expect(session.timeline.layout.viewport == target)
      #expect(publishedViewports.count == beforeCount + 1)
      #expect(publishedViewports.last == target)
      #expect(abs(session.timeline.layout.originY - bouncedOrigin(distance)) < 0.001)
      #expect(session.timeline.layout.rows.allSatisfy { $0.frame.height == 40 })
      #expect(session.snapshot?.items.first?.revision == 0)
      #expect(session.generation == 1)
      #expect(session.isUserScrolling)
      #expect(session.timeline.intent != requested)

      session.advance(to: Double(index + 1) + 0.5)
      #expect(session.timeline.layout.viewport == target)
      #expect(abs(session.timeline.layout.originY - bouncedOrigin(distance)) < 0.001)
      session.endUserScroll(at: bouncedOrigin(distance), time: Double(index + 1) + 0.5)
      #expect(session.isUserScrolling)
      #expect(session.generation == 1)
    }
    let atomicViewport = TimelineViewport(width: 320, height: 480, topInset: 50, bottomInset: 160)
    let atomicContext = ChatListLayoutContext(width: 320, displayScale: 2)
    let atomicResult = try session.apply(
      snapshot(context: atomicContext, revision: 2, height: 70, history: history),
      animation: .none, at: 2.6, viewport: atomicViewport
    )
    #expect(atomicResult == .deferred)
    var heldWidthViewport = atomicViewport
    heldWidthViewport.width = viewport.width
    #expect(session.timeline.layout.viewport == heldWidthViewport)
    #expect(publishedViewports.last == heldWidthViewport)
    #expect(session.layoutContext == atomicContext)
    #expect(session.snapshot?.context.width == viewport.width)
    #expect(session.snapshot?.items.first?.revision == 0)
    #expect(session.timeline.layout.rows.allSatisfy { $0.frame.width == viewport.width && $0.frame.height == 40 })
    #expect(abs(session.timeline.layout.originY - bouncedOrigin(11)) < 0.001)
    #expect(session.generation == 1)
    let legalOrigin = bouncingAtBottom ? session.timeline.layout.maximumOrigin : 0
    session.endUserScroll(at: legalOrigin, time: 3)
    #expect(!session.isUserScrolling)
    #expect(session.snapshot?.items.first?.revision == 2)
    #expect(session.snapshot?.context == atomicContext)
    #expect(session.timeline.layout.viewport == atomicViewport)
    #expect(session.generation == 2)
    #expect(session.timeline.intent == requested)
    #expect(session.timeline.layout.rows.allSatisfy { $0.frame.height == 70 })
  }

  @Test(arguments: [false, true])
  func `animated occlusions advance during native bounce while existing row and child motion stays frozen`(
    bouncingAtBottom: Bool
  ) throws {
    let session = session()
    defer { session.dispose() }
    func content(height: CGFloat, revision: UInt64) -> Snapshot {
      var items = snapshot().items
      items[15] = .init(id: 15, revision: revision, content: "changing cell", height: height,
                        elements: ["child": CGRect(x: 0, y: height - 20, width: 100, height: 20)])
      return .init(context: .init(width: 600), items: items,
                   history: .init(hasOlder: true, hasNewer: true, isAtLiveEnd: false))
    }
    try session.apply(content(height: 100, revision: 0), animation: .none, at: 0)
    try session.apply(content(height: 600, revision: 1), animation: .animated, at: 0)
    session.advance(to: 0.05)
    let frozenRows = session.timeline.layout.rows.map(\.row)
    let frozenOpacities = session.timeline.layout.rows.map(\.opacity)
    let frozenHeight = try #require(session.timeline.layout.placement(for: 15)?.frame.height)
    #expect(frozenHeight > 100 && frozenHeight < 600)
    let distance: CGFloat = 24
    let origin = bouncingAtBottom ? session.timeline.layout.maximumOrigin + distance : -distance
    session.beginUserScroll(at: origin)
    session.userScrolled(to: origin)
    var target = viewport
    target.topInset = 120
    target.bottomInset = 220
    session.updateViewport(target, animation: .animated, at: 0.05)
    for frame in 0 ... 120 {
      session.advance(to: 0.05 + Double(frame) / 120)
      let layout = session.timeline.layout
      let expectedOrigin = bouncingAtBottom ? layout.maximumOrigin + distance : -distance
      #expect(abs(layout.originY - expectedOrigin) < 0.001)
      #expect(layout.rows.map(\.row) == frozenRows)
      #expect(layout.rows.map(\.opacity) == frozenOpacities)
      let topProgress = (layout.viewport.topInset - viewport.topInset) / (target.topInset - viewport.topInset)
      let bottomProgress = (layout.viewport.bottomInset - viewport.bottomInset) / (target.bottomInset - viewport.bottomInset)
      #expect(abs(topProgress - bottomProgress) < 0.001)
      if frame == 6 {
        #expect(topProgress > 0 && topProgress < 1)
        #expect(bottomProgress > 0 && bottomProgress < 1)
      }
      #expect(session.generation == 2)
      #expect(session.isUserScrolling)
    }
    #expect(session.timeline.layout.viewport == target)
    #expect(session.timeline.isAnimating)
    let legalOrigin = bouncingAtBottom ? session.timeline.layout.maximumOrigin : 0
    session.endUserScroll(at: legalOrigin, time: 1.05)
    #expect(session.timeline.layout.rows.map(\.row) == frozenRows)
    session.advance(to: 1.06)
    let resumedHeight = try #require(session.timeline.layout.placement(for: 15)?.frame.height)
    #expect(resumedHeight > frozenHeight && resumedHeight < 600)
    session.advance(to: 3)
    #expect(session.timeline.layout.placement(for: 15)?.frame.height == 600)
    #expect(!session.timeline.isAnimating)
  }

  @Test func `new native input revokes deferred programmatic navigation`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    session.beginUserScroll(at: -20)
    session.navigate(to: .latest, animation: .none, at: 1)
    session.beginUserScroll(at: -10)
    session.userScrolled(to: 100)
    session.endUserScroll(at: 100, time: 2)
    #expect(session.timeline.intent != .latest)
    #expect(abs(session.timeline.layout.originY - 100) < 0.001)
  }

  @Test func `ending native input does not snap an existing inset animation`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    var target = viewport
    target.topInset = 120
    target.bottomInset = 160
    session.updateViewport(target, animation: .animated, at: 0)
    session.advance(to: 0.03)
    let presented = session.timeline.layout.viewport
    #expect(presented.topInset > viewport.topInset && presented.topInset < target.topInset)
    session.beginUserScroll(at: 100)
    session.endUserScroll(at: 100, time: 0.03)
    #expect(session.timeline.layout.viewport == presented)
    #expect(session.timeline.isAnimating)
    session.advance(to: 0.04)
    #expect(session.timeline.layout.viewport.topInset > presented.topInset)
    #expect(session.timeline.layout.viewport.topInset < target.topInset)
  }

  @Test func `uncached newer history prevents settlement from silently entering latest mode`() throws {
    let session = session()
    try session.apply(snapshot(history: .init(hasNewer: true, isAtLiveEnd: false)), animation: .none, at: 0)
    let end = session.timeline.layout.maximumOrigin
    session.beginUserScroll(at: end)
    session.endUserScroll(at: end, time: 1)
    #expect(session.timeline.intent != .latest)
  }

  @Test func `semantic anchor follows animated child geometry during simultaneous inset and height change`() throws {
    let session = session()
    func richSnapshot(childY: CGFloat, height: CGFloat) -> Snapshot {
      var items = snapshot().items
      items[15] = .init(id: 15, revision: UInt64(childY), content: "opaque interactive cell", height: height,
                        elements: ["content": CGRect(x: 0, y: childY, width: 500, height: 700)])
      return .init(context: .init(width: 600), items: items)
    }
    try session.apply(richSnapshot(childY: 100, height: 1_000),
                      intent: .reading(.init(id: 15, localY: 300, viewportY: 30)), animation: .none, at: 0)
    let oldRow = try #require(session.timeline.layout.placement(for: 15))
    let oldChild = try #require(oldRow.row.elements["content"])
    let contentOffset = session.timeline.layout.readingRect.maxY - oldRow.frame.minY - oldChild.minY
    var nextViewport = viewport
    nextViewport.topInset = 95
    nextViewport.bottomInset = 140
    try session.apply(richSnapshot(childY: 400, height: 1_300), animation: .animated,
                      at: 0, viewport: nextViewport)
    let location = ChatListAnchorLocation(element: "content", offsetY: contentOffset)
    for frame in 0 ... 240 {
      session.advance(to: Double(frame) / 120)
      #expect(session.refineAnchor(row: 15, location: location, viewportY: 0, edge: .bottom))
      let row = try #require(session.timeline.layout.placement(for: 15))
      let child = try #require(row.row.elements["content"])
      #expect(abs(row.frame.minY + child.minY + contentOffset - session.timeline.layout.readingRect.maxY) < 0.001)
    }
    #expect(!session.timeline.isAnimating)
    let origin = session.timeline.layout.originY
    session.advance(to: 4)
    #expect(abs(session.timeline.layout.originY - origin) < 0.001)
  }

  @Test func `unavailable semantic anchor leaves prior reading position intact`() throws {
    let session = session()
    try session.apply(snapshot(), intent: .reading(.init(id: 15, localY: 3)), animation: .none, at: 0)
    let origin = session.timeline.layout.originY
    #expect(!session.refineAnchor(row: 15, location: .init(element: "absent", offsetY: 2), viewportY: 0))
    #expect(!session.refineAnchor(row: 15, location: .init(offsetY: .nan), viewportY: 0))
    #expect(!session.refineAnchor(row: 999, location: .init(offsetY: 0), viewportY: 0))
    #expect(session.timeline.layout.originY == origin)
  }

  @Test func `inactive session freezes presentation and installs only newest deferred snapshot`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    session.setActive(false, at: 1)
    let origin = session.timeline.layout.originY
    #expect(try session.apply(snapshot(revision: 1), animation: .none, at: 2) == .deferred)
    #expect(try session.apply(snapshot(revision: 2), animation: .none, at: 3) == .deferred)
    session.advance(to: 100)
    #expect(session.generation == 1)
    #expect(session.timeline.layout.originY == origin)
    session.setActive(true, at: 100)
    #expect(session.snapshot?.items.first?.revision == 2)
    #expect(session.generation == 2)
  }

  @Test func `resuming an unchanged viewport preserves paused inset spring presentation`() throws {
    let session = session()
    try session.apply(snapshot(), animation: .none, at: 0)
    var target = viewport
    target.bottomInset = 180
    session.updateViewport(target, animation: .animated, at: 0)
    session.advance(to: 0.04)
    let presented = session.timeline.layout.viewport
    session.setActive(false, at: 0.04)
    session.advance(to: 1_000)
    session.setActive(true, at: 1_000)
    #expect(session.timeline.layout.viewport == presented)
    #expect(session.timeline.isAnimating)
    session.advance(to: 1_000.01)
    #expect(session.timeline.layout.viewport.bottomInset > presented.bottomInset)
    #expect(session.timeline.layout.viewport.bottomInset < target.bottomInset)
  }

  @Test(arguments: [false, true])
  func `hide and resume retain animated navigation intent and exclude paused time`(toLatest: Bool) throws {
    let session = session()
    let reference = self.session()
    let initial: TimelineIntent<Int> = toLatest ? .reading(.init(id: 3)) : .latest
    let destination: TimelineIntent<Int> = toLatest ? .latest : .reading(.init(id: 3, localY: 9, viewportY: 23))
    for candidate in [session, reference] {
      try candidate.apply(snapshot(Array(0 ..< 80)), intent: initial, animation: .none, at: 0)
      candidate.navigate(to: destination, animation: .animated, at: 0)
      candidate.advance(to: 0.04)
    }
    let pausedOrigin = session.timeline.layout.originY
    #expect(session.timeline.isAnimating)
    session.setActive(false, at: 0.04)
    session.advance(to: 1_000)
    #expect(session.timeline.intent == destination)
    #expect(session.timeline.layout.originY == pausedOrigin)
    session.setActive(true, at: 1_000)
    #expect(session.timeline.intent == destination)
    #expect(session.timeline.layout.originY == pausedOrigin)
    #expect(session.timeline.isAnimating)

    session.advance(to: 1_000.05)
    reference.advance(to: 0.09)
    #expect(abs(session.timeline.layout.originY - reference.timeline.layout.originY) < 0.001)
    #expect(session.timeline.intent == destination)
    session.advance(to: 1_002)
    #expect(!session.timeline.isAnimating)
    if toLatest {
      #expect(abs(session.timeline.layout.originY - session.timeline.layout.maximumOrigin) < 0.001)
    } else {
      let row = try #require(session.timeline.layout.placement(for: 3))
      #expect(abs(row.frame.minY + 9 - session.timeline.layout.readingRect.minY - 23) < 0.001)
    }
  }

  @Test(arguments: ["cancelled active", "skipped inactive", "manual then skipped"])
  func `resume requests same context refresh for work lost while inactive`(scenario: String) async throws {
    let session = session()
    defer { session.dispose() }
    try session.apply(snapshot([1]), animation: .none, at: 0)
    let gate = ControlledPreparation()
    var refreshes: [(ChatListLayoutContext, UInt64?)] = []
    var skippedProviderCalls = 0
    session.onNeedsSnapshot = { context in
      refreshes.append((context, session.snapshot?.items.first?.revision))
    }
    if scenario == "cancelled active" {
      session.requestPreparation(identities: [1], animation: .none, prepare: gate.prepare)
      await gate.waitUntilStarted()
    }
    session.setActive(false, at: 1)
    if scenario == "manual then skipped" {
      #expect(try session.apply(snapshot([1], revision: 1), animation: .none, at: 1) == .deferred)
    }
    if scenario == "cancelled active" {
      gate.succeed(snapshot([1], revision: 2))
      await drainReadyTasks()
    } else {
      session.requestPreparation(identities: [1], animation: .none) { context in
        skippedProviderCalls += 1
        return self.snapshot([1], context: context, revision: 2)
      }
    }
    #expect(refreshes.isEmpty)
    #expect(skippedProviderCalls == 0)
    session.setActive(true, at: 2)
    #expect(refreshes.count == 1)
    #expect(refreshes.first?.0 == .init(width: 600))
    #expect(refreshes.first?.1 == (scenario == "manual then skipped" ? 1 : 0))
    #expect(session.snapshot?.context == session.layoutContext)
    session.setActive(true, at: 3)
    session.advance(to: 4)
    #expect(refreshes.count == 1)
    #expect(skippedProviderCalls == 0)
  }

  @Test func `streamed content at the same history boundary does not repeat an edge demand`() throws {
    let session = session()
    var olderRequests = 0
    session.onHistoryDemand = { edge in
      if case .older = edge { olderRequests += 1 }
    }
    let history = ChatListHistoryAvailability(hasOlder: true)
    try session.apply(snapshot(history: history), intent: .reading(.init(id: 0)), animation: .none, at: 0)
    session.didPresent()
    for revision in 1 ... 20 {
      try session.apply(snapshot(revision: UInt64(revision), history: history), animation: .none, at: 0)
      session.didPresent()
    }
    #expect(olderRequests == 1)
    session.navigate(to: .reading(.init(id: 20)), animation: .none, at: 1)
    session.didPresent()
    session.navigate(to: .reading(.init(id: 0)), animation: .none, at: 2)
    session.didPresent()
    #expect(olderRequests == 2)
  }

  @Test func `short middle window requests both history edges on the same presentation`() throws {
    let session = session()
    var requests: [String] = []
    session.onHistoryDemand = { edge in
      switch edge {
        case .older: requests.append("older")
        case .newer: requests.append("newer")
      }
    }
    let history = ChatListHistoryAvailability(hasOlder: true, hasNewer: true, isAtLiveEnd: false)
    try session.apply(snapshot([1], history: history), animation: .none, at: 0)
    #expect(requests.isEmpty)
    session.didPresent()
    #expect(requests == ["older", "newer"])
    session.didPresent()
    #expect(requests == ["older", "newer"])
    try session.apply(snapshot([1], revision: 1, history: history), animation: .none, at: 1)
    session.didPresent()
    #expect(requests == ["older", "newer"])
    session.rearmHistoryDemand(at: .newer)
    session.didPresent()
    #expect(requests == ["older", "newer", "newer"])
  }

  @Test func `inactive session cancels asynchronous work and cannot accept its late completion`() async throws {
    let session = session()
    try session.apply(snapshot([1]), animation: .none, at: 0)
    let gate = ControlledPreparation()
    session.requestPreparation(identities: [1], animation: .none, prepare: gate.prepare)
    await gate.waitUntilStarted()
    session.setActive(false, at: 1)
    gate.succeed(snapshot([1], revision: 1))
    await drainReadyTasks()
    session.setActive(true, at: 2)
    #expect(session.snapshot?.items.first?.revision == 0)
    #expect(session.generation == 1)
  }

  @Test func `dispose releases arbitrary installed and deferred payloads and consumer closures`() throws {
    final class Payload {}
    let session = ChatListSession<Int, Payload>(viewport: viewport, now: { 0 })
    weak var installed: Payload?
    weak var deferred: Payload?
    weak var callbackCapture: Payload?
    do {
      let first = Payload()
      installed = first
      try session.apply(.init(context: .init(width: 600), items: [
        .init(id: 1, revision: 0, content: first, height: 40)
      ]), animation: .none, at: 0)
      let captured = Payload()
      callbackCapture = captured
      session.onPresentation = { _ in withExtendedLifetime(captured) {} }
      session.setActive(false, at: 1)
      let pending = Payload()
      deferred = pending
      try session.apply(.init(context: .init(width: 600), items: [
        .init(id: 2, revision: 0, content: pending, height: 40)
      ]), animation: .none, at: 1)
    }
    #expect(installed != nil)
    #expect(deferred != nil)
    #expect(callbackCapture != nil)
    session.dispose()
    #expect(installed == nil)
    #expect(deferred == nil)
    #expect(callbackCapture == nil)
    #expect(session.snapshot == nil)
    #expect(session.item(for: 1) == nil)
    #expect(session.isDisposed)
    #expect(throws: ChatListError.disposed) {
      try session.apply(.init(context: .init(width: 600), items: []), at: 2)
    }
    session.dispose()
  }

  @Test func `disposed session cannot be revived by late preparation completion`() async throws {
    let session = session()
    let gate = ControlledPreparation()
    var callbacks = 0
    session.onPreparationError = { _ in callbacks += 1 }
    session.onPresentationChanged = { callbacks += 1 }
    session.requestPreparation(identities: [1], animation: .none, prepare: gate.prepare)
    await gate.waitUntilStarted()
    session.dispose()
    gate.succeed(snapshot([1]))
    await drainReadyTasks()
    #expect(session.snapshot == nil)
    #expect(session.generation == 0)
    #expect(callbacks == 0)
  }

  /// Every asynchronous provider is released by an explicit continuation. This
  /// drain permits the finite completion/pending task chain to execute without
  /// depending on a wall-clock delay or a background executor doing work.
  private func drainReadyTasks() async {
    for _ in 0 ..< 32 { await Task.yield() }
  }

  private enum PreparationFailure: Error { case expected }

  @MainActor
  private final class ControlledPreparation {
    private var continuation: CheckedContinuation<Snapshot, any Error>?
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(_ context: ChatListLayoutContext) async throws -> Snapshot {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }

    func waitUntilStarted() async {
      guard !started else { return }
      await withCheckedContinuation { startedWaiters.append($0) }
    }

    func succeed(_ snapshot: Snapshot) {
      let pending = continuation
      continuation = nil
      pending?.resume(returning: snapshot)
    }

    func fail(_ error: any Error) {
      let pending = continuation
      continuation = nil
      pending?.resume(throwing: error)
    }
  }
}
