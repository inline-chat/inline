import SwiftUI
import TimelineCore
import TimelineUIKit
import UIKit

/// E1: the real engine (`TimelineListView`) over generated rows, with buttons for every kind of change.
struct EngineScreen: UIViewRepresentable {
  func makeUIView(context: Context) -> EngineDemoView { EngineDemoView() }
  func updateUIView(_ uiView: EngineDemoView, context: Context) {}
}

@MainActor
final class EngineDemoView: UIView {
  private var ids: [Int] = []
  private var heights: [Int: CGFloat] = [:]
  private var nextID = 0
  private var oldestID = 0
  private var seed: UInt64 = 0x9E37_79B9
  private var timeline: TimelineListView<Int>!
  private let bar = UIStackView()
  private let status = UILabel()
  private var insetRaised = false
  private let rowCost = Double(Lab.arg("rowcost") ?? "0") ?? 0

  init() {
    super.init(frame: .zero)
    backgroundColor = .systemBackground
    let count = Int(Lab.arg("rows") ?? "2000") ?? 2000
    for _ in 0 ..< count { appendRow() }

    timeline = TimelineListView(rows: TimelineRows(
      height: { [unowned self] id, _ in heights[id] ?? 60 },
      make: { [unowned self] id, _ in makeRow(id) },
      update: { [unowned self] id, view, _, _ in (view as? DemoRow)?.label.text = "row \(id)  h=\(Int(heights[id] ?? 0))" }
    ))
    timeline.accessibilityIdentifier = "timeline"
    timeline.onLayout = { [weak self] layout in self?.report(layout) }
    timeline.onDemand = { [weak self] edges in if edges.contains(.older) { self?.loadOlder() } }
    addSubview(timeline)

    bar.axis = .horizontal
    bar.distribution = .fillEqually
    bar.spacing = 4
    bar.backgroundColor = UIColor.secondarySystemBackground
    for (title, action) in [
      ("Add", #selector(add)), ("Del", #selector(deleteRow)), ("Grow", #selector(grow)), ("Inset", #selector(toggleInset)),
      ("Top", #selector(jumpTop)), ("Mid", #selector(jumpMiddle)), ("End", #selector(jumpEnd)),
    ] {
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal)
      button.accessibilityIdentifier = "e1." + title
      button.addTarget(self, action: action, for: .touchUpInside)
      bar.addArrangedSubview(button)
    }
    addSubview(bar)
    status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
    status.textColor = .secondaryLabel
    status.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
    status.accessibilityIdentifier = "e1.status"
    addSubview(status)

    timeline.apply(TimelineTransaction(rows: ids, coverage: coverage, scroll: .latest))
    if Lab.arg("e1auto") == "1" { Task { await runAuto() } }
  }

  // MARK: - Scripted run (no touches): continuity and coverage of the real engine

  private var probeLink: CADisplayLink?
  private var probeLast: CGFloat?
  private var probeLastStep: CGFloat?
  private var probeMaxStep: CGFloat = 0
  private var probeMaxJerk: CGFloat = 0
  private var probeUncovered: CGFloat = 0
  private var probeFrames = 0

  @objc private func probeTick() {
    let d = timeline.diagnostics
    probeFrames += 1
    // Rows must cover what is on screen: any gap here would be a blank band.
    let uncovered = max(0, d.placedTop - d.presentedScrollPosition, d.presentedScrollPosition + timeline.bounds.height - d.placedBottom)
    if d.placedCount > 0, !atDataEdge { probeUncovered = max(probeUncovered, uncovered) }
    if let last = probeLast {
      let step = d.presentedScrollPosition - last
      probeMaxStep = max(probeMaxStep, abs(step))
      if let lastStep = probeLastStep { probeMaxJerk = max(probeMaxJerk, abs(step - lastStep)) }
      probeLastStep = step
    }
    probeLast = d.presentedScrollPosition
    if probeTrace { Lab.log(String(format: "E1 trace presented=%.1f settled=%.1f", d.presentedScrollPosition, d.scrollPosition)) }
  }

  private var probeTrace = false

  private var atDataEdge: Bool {
    guard let first = timeline.layout.placements.first, let last = timeline.layout.placements.last else { return true }
    return first.index == 0 || last.index == ids.count - 1
  }

  private func probe(_ name: String, _ body: () async -> Void) async {
    probeLast = nil; probeLastStep = nil; probeMaxStep = 0; probeMaxJerk = 0; probeUncovered = 0; probeFrames = 0
    let before = timeline.diagnostics.presentedScrollPosition
    await body()
    let after = timeline.diagnostics
    Lab.log(String(format: "E1 %@: frames=%d travel=%.1f maxStep=%.1f maxJerk=%.2f uncovered=%.1f settled=%.2f presented=%.2f position=%@ atBottom=%d decelerating=%d rows=%d",
                   name, probeFrames, after.presentedScrollPosition - before, probeMaxStep, probeMaxJerk, probeUncovered,
                   after.scrollPosition, after.presentedScrollPosition, "\(timeline.position)", timeline.layout.isAtBottom ? 1 : 0,
                   timeline.isDecelerating ? 1 : 0, ids.count))
  }

  private func runAuto() async {
    await Lab.sleep(1.0)
    let link = CADisplayLink(target: self, selector: #selector(probeTick))
    link.add(to: .main, forMode: .common)
    probeLink = link

    for velocity in (Lab.arg("e1quick") == "1" ? [] : [1000.0, 3000.0, 6000.0]) {
      timeline.apply(TimelineTransaction(scroll: .latest))
      await Lab.sleep(0.3)
      await probe("fling \(Int(velocity))") { timeline.fling(velocity: velocity); await Lab.sleep(4.0) }
    }
    timeline.apply(TimelineTransaction(scroll: .to(ids[ids.count - 9], .top(0))))
    await Lab.sleep(0.3)
    await probe("fling into newest end") { timeline.fling(velocity: -5000); await Lab.sleep(3.5) }
    await probe("pull-like release past the end") { timeline.fling(velocity: -900); await Lab.sleep(1.5) }

    for delay in [0.15, 0.4, 0.9] {
      timeline.apply(TimelineTransaction(scroll: .latest))
      await Lab.sleep(0.3)
      timeline.fling(velocity: 4000)
      await Lab.sleep(delay)
      let before = timeline.diagnostics.presentedScrollPosition
      timeline.stopScrolling()
      let stopped = timeline.diagnostics
      await Lab.sleep(0.2)
      let later = timeline.diagnostics.presentedScrollPosition
      Lab.log(String(format: "E1 catch after %.2f: presented before=%.2f model after=%.2f snap=%.2f drift after 0.2s=%.2f", delay, before, stopped.scrollPosition, stopped.scrollPosition - before, later - stopped.scrollPosition))
    }

    if Lab.arg("e1quick") == "1" {
      timeline.apply(TimelineTransaction(scroll: .latest))
      await Lab.sleep(0.3)
      probeTrace = true
      await probe("inset up") { toggleInset(); await Lab.sleep(0.7) }
      await probe("inset down then up 120 ms later") {
        toggleInset(); await Lab.sleep(0.12); Lab.log("E1 trace reverse"); toggleInset(); await Lab.sleep(1.0)
      }
      probeTrace = false
      link.invalidate()
      Lab.write("e1auto.done", "done")
      Lab.flushEvents()
      return
    }
    // Stalls: the content has to keep moving on screen while the main thread is blocked.
    timeline.apply(TimelineTransaction(scroll: .latest))
    await Lab.sleep(0.3)
    await probe("fling 4000 with three 80 ms stalls") {
      timeline.fling(velocity: 4000)
      for _ in 0 ..< 3 {
        await Lab.sleep(0.12)
        let a = timeline.diagnostics.presentedScrollPosition
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 0.08 {}
        let b = timeline.diagnostics.presentedScrollPosition
        Lab.log(String(format: "E1 stall: presented moved %.1f during an 80 ms block", b - a))
      }
      await Lab.sleep(3.5)
    }

    // Older pages arriving mid-fling (the lab loads 150 rows 50 ms after each demand).
    timeline.apply(TimelineTransaction(scroll: .to(ids[40], .top(0))))
    await Lab.sleep(0.3)
    await probe("fling 5000 through four prepends") { timeline.fling(velocity: 5000); await Lab.sleep(5.0) }
    for round in 0 ..< 5 {
      await probe("fling 9000 towards the oldest end #\(round)") { timeline.fling(velocity: 9000); await Lab.sleep(4.5) }
    }

    // Changes while pinned, stacked faster than they settle.
    timeline.apply(TimelineTransaction(scroll: .latest))
    await Lab.sleep(0.3)
    await probe("three adds 80 ms apart") {
      for _ in 0 ..< 3 { add(); await Lab.sleep(0.08) }
      await Lab.sleep(1.0)
    }
    probeTrace = true
    await probe("inset up") { toggleInset(); await Lab.sleep(0.7) }
    await probe("inset down then up 120 ms later") {
      toggleInset(); await Lab.sleep(0.12); Lab.log("E1 trace reverse"); toggleInset(); await Lab.sleep(1.0)
    }
    probeTrace = false
    toggleInset(); await Lab.sleep(0.6)
    await probe("inset change during a fling") {
      timeline.fling(velocity: 3000); await Lab.sleep(0.2); toggleInset(); await Lab.sleep(4.0); toggleInset(); await Lab.sleep(0.8)
    }
    await probe("grow and delete while reading") { grow(); await Lab.sleep(0.6); deleteRow(); await Lab.sleep(0.8) }

    link.invalidate()
    Lab.write("e1auto.done", "done")
    Lab.flushEvents()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// The lab pretends older history exists until 600 more rows were loaded.
  private var coverage: TimelineCoverage { TimelineCoverage(reachesOldest: oldestID <= -600, reachesNewest: true) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let barHeight: CGFloat = 44 + safeAreaInsets.bottom
    timeline.frame = bounds
    bar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: 44)
    status.frame = CGRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: 14)
    timeline.setInsets(top: safeAreaInsets.top + 14, bottom: barHeight + (insetRaised ? 300 : 0))
  }

  private func nextHeight() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(44 + Int(Double(seed >> 33) / Double(1 << 31) * 140))
  }

  private func appendRow() {
    ids.append(nextID)
    heights[nextID] = nextHeight()
    nextID += 1
  }

  private func makeRow(_ id: Int) -> UIView {
    if rowCost > 0 {
      let start = CACurrentMediaTime()
      while (CACurrentMediaTime() - start) * 1000 < rowCost {}
    }
    let row = DemoRow()
    row.label.text = "row \(id)  h=\(Int(heights[id] ?? 0))"
    let hue = Double(abs(id &* 7919) % 100) / 100
    row.bubble.backgroundColor = UIColor(hue: hue, saturation: 0.3, brightness: 0.95, alpha: 1)
    return row
  }

  private func report(_ layout: TimelineLayout<Int>) {
    let position: String = switch layout.position {
      case .latest: "latest"
      case let .row(id, top): "row \(id) top \(Int(top))"
    }
    status.text = " \(position)  placed \(layout.placements.count)  bottom \(layout.isAtBottom)  rows \(ids.count)"
  }

  private func loadOlder() {
    guard oldestID > -600, !loadingOlder else { return }
    loadingOlder = true
    // Arrives a moment later, like a page from the database.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
      loadingOlder = false
      var page: [Int] = []
      for _ in 0 ..< 150 {
        oldestID -= 1
        heights[oldestID] = nextHeight()
        page.insert(oldestID, at: 0)
      }
      ids = page + ids
      timeline.apply(TimelineTransaction(rows: ids, coverage: coverage))
    }
  }

  private var loadingOlder = false

  @objc private func add() {
    appendRow()
    timeline.apply(TimelineTransaction(rows: ids, timing: .standard))
  }

  @objc private func deleteRow() {
    guard let target = timeline.layout.visible.dropLast().last?.id, let index = ids.firstIndex(of: target) else { return }
    ids.remove(at: index)
    timeline.apply(TimelineTransaction(rows: ids, timing: .standard))
  }

  @objc private func grow() {
    guard let target = timeline.layout.visible.dropLast().last?.id else { return }
    heights[target, default: 60] += 60
    timeline.apply(TimelineTransaction(changed: [target], timing: .standard))
  }

  @objc private func toggleInset() {
    insetRaised.toggle()
    let barHeight: CGFloat = 44 + safeAreaInsets.bottom
    timeline.setInsets(bottom: barHeight + (insetRaised ? 300 : 0), timing: .keyboard)
  }

  @objc private func jumpTop() {
    guard let first = ids.first else { return }
    timeline.apply(TimelineTransaction(scroll: .to(first, .top(0)), timing: .standard))
  }

  @objc private func jumpMiddle() {
    timeline.apply(TimelineTransaction(scroll: .to(ids[ids.count / 2], .center), timing: .standard))
  }

  @objc private func jumpEnd() {
    timeline.apply(TimelineTransaction(scroll: .latest, timing: .standard))
  }
}

private final class DemoRow: UIView {
  let bubble = UIView()
  let label = UILabel()

  init() {
    super.init(frame: .zero)
    bubble.layer.cornerRadius = 10
    addSubview(bubble)
    label.font = .systemFont(ofSize: 13)
    label.textColor = .darkGray
    bubble.addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    bubble.frame = bounds.insetBy(dx: 8, dy: 3)
    label.frame = CGRect(x: 10, y: 6, width: bubble.bounds.width - 20, height: 18)
  }
}
