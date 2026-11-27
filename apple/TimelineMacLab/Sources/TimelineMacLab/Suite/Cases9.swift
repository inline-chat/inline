import AppKit
import CoreText
import TimelineAppKit
import TimelineCore

// Text in a layer (Telegram's `TextViewLayer` pattern) against AppKit's drawing gate (design doc pitfall 11): AppKit
// draws an NSView only inside the model's visible rect and drops `needsDisplay` set outside it. Does a plain CALayer
// sublayer drawn from a prebuilt Core Text frame draw when its row is configured while the model sits elsewhere?

/// Text drawn by Core Animation from a Core Text frame built at configure time; records what it last drew.
final class LabTextLayer: CALayer {
  private(set) var drawnText: String?
  private var frameText: String = ""
  private var ctFrame: CTFrame?

  override init() {
    super.init()
    needsDisplayOnBoundsChange = false
  }

  override init(layer: Any) { super.init(layer: layer) }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // No implicit animations (Telegram: null actions).
  override func action(forKey event: String) -> (any CAAction)? { NSNull() }

  func configure(_ text: String, size: CGSize) {
    frameText = text
    let attributed = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
    ])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    ctFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
    setNeedsDisplay()
  }

  override func draw(in ctx: CGContext) {
    guard let ctFrame else { return }
    ctx.textMatrix = .identity
    CTFrameDraw(ctFrame, ctx)
    drawnText = frameText
  }

  var showsItsText: Bool { drawnText == frameText && !frameText.isEmpty }
}

/// A row with the same text twice: an NSTextField (AppKit drawing) and a layer drawn by Core Animation.
final class LabLayerTextRow: NSView {
  let label = LabLabel(labelWithString: "")
  let textLayer = LabTextLayer()
  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    label.font = .systemFont(ofSize: 13)
    addSubview(label)
    layer?.addSublayer(textLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(_ text: String, width: CGFloat, scale: CGFloat) {
    label.stringValue = text
    label.frame = NSRect(x: 12, y: 6, width: max(10, width / 2 - 24), height: 20)
    textLayer.frame = CGRect(x: width / 2, y: 6, width: max(10, width / 2 - 12), height: 22)
    textLayer.contentsScale = scale
    textLayer.configure(text, size: textLayer.bounds.size)
  }
}

extension SuiteCases {
  static var layerText: [BehaviourCase] {
    [
      BehaviourCase(
        id: "draw.layer-text-parked-model", area: "Drawing",
        behaviour: "Rows reconfigured while the content's model is parked 5,000 pt away from what the screen shows (the old fling state): text drawn by Core Animation in a layer draws (NSTextField counts noted)"
      ) { b, c in
        let scale = b.window.backingScaleFactor
        let rowHeight: CGFloat = 34
        let window = NSWindow(
          contentRect: NSRect(x: 620, y: 80, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // 1. The engine, as the fling used to leave it: rows on screen, the content's model parked at a motion's end.
        let list = TimelineListView<Int>(rows: TimelineRows(
          height: { _, _ in rowHeight },
          make: { id, width in
            let row = LabLayerTextRow()
            row.configure("row \(id) first", width: width, scale: scale)
            return row
          }
        ))
        list.frame = window.contentView!.bounds
        window.contentView!.addSubview(list)
        list.layoutSubtreeIfNeeded()
        list.apply(TimelineTransaction(
          rows: Array(0 ..< 300), coverage: TimelineCoverage(reachesOldest: true, reachesNewest: true), scroll: .latest
        ))
        await b.frames(4)
        let parked = await parkAndReconfigure(content: list.content, rows: list.placedViews.map(\.1), width: list.bounds.width, scale: scale, b: b)
        c.note("engine: \(parked.summary)")
        c.that("engine: model parked through the check", parked.stayedParked)
        c.atLeast("engine: rows on screen", Double(parked.rows), 5, unit: "")
        c.near("engine: layer-text rows that drew their new text", Double(parked.layersDrawn), Double(parked.rows), within: 0)
        list.content.layer?.removeAnimation(forKey: "lab.park")
        list.apply(TimelineTransaction(scroll: .latest))
        await b.frames(2)

        // 2. Plain AppKit, no engine: a clipping container, a flipped content view whose bounds origin is parked
        // 5,000 pt away, shown where it was by an additive animation; rows configured while parked. Variants: views
        // that clip (clipsToBounds, as UIKit's list does), and rows configured inside AppKit's layout pass.
        list.removeFromSuperview()
        for (name, clips, inLayout) in [("plain", false, false), ("plain, clipsToBounds", true, false), ("plain, configured in layout()", false, true), ("plain, clips + layout()", true, true)] {
          let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
          container.wantsLayer = true
          container.layer?.masksToBounds = true
          container.clipsToBounds = clips
          let content = FlippedLabView(frame: container.bounds)
          content.wantsLayer = true
          content.clipsToBounds = clips
          container.addSubview(content)
          window.contentView!.addSubview(container)
          var rows: [LabLayerTextRow] = []
          for i in 0 ..< 16 {
            let row = LabLayerTextRow()
            row.frame = NSRect(x: 0, y: CGFloat(i) * rowHeight, width: 520, height: rowHeight)
            row.clipsToBounds = clips
            row.configure("plain \(i) first", width: 520, scale: scale)
            content.addSubview(row)
            rows.append(row)
          }
          await b.frames(4)
          let plain = await parkAndReconfigure(content: content, rows: rows, width: 520, scale: scale, b: b, inLayout: inLayout)
          c.note("\(name): \(plain.summary)")
          c.near("\(name): layer-text rows that drew their new text", Double(plain.layersDrawn), Double(plain.rows), within: 0)
          // Back where shown, no new invalidation: did AppKit keep the dropped needsDisplay?
          await b.frames(3)
          c.note("\(name): after the model returned, NSTextField rows drawn without a new invalidation: \(rows.filter(\.label.showsItsText).count)/\(rows.count)")
          // Control: the same reconfigure with the model where the screen shows it: both draw.
          for (i, row) in rows.enumerated() { row.configure("plain \(i) control", width: 520, scale: scale) }
          await b.frames(3)
          let controlLabels = rows.filter(\.label.showsItsText).count
          c.near("\(name) control: NSTextField rows drawn", Double(controlLabels), Double(rows.count), within: 0)
          container.removeFromSuperview()
        }
      },
      layerTextMotion,
    ]
  }

  /// The engine in motion, an animated jump of ~10,000 pt with recycled rows, with the model either following what is
  /// shown (as it does) or parked at the motion's end (the old state: before each commit the follow hold is folded
  /// into the content's bounds). After each commit: rows shown on screen whose NSTextField / layer text is undrawn.
  static var layerTextMotion: BehaviourCase {
    BehaviourCase(
      id: "draw.layer-text-parked-motion", area: "Drawing",
      behaviour: "An animated 10,000 pt jump through recycled rows with the content's model parked at the jump's end each frame (the old state): NSTextField rows on screen go undrawn, layer-text rows draw"
    ) { b, c in
      let scale = b.window.backingScaleFactor
      let window = NSWindow(
        contentRect: NSRect(x: 620, y: 80, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false
      )
      window.isReleasedWhenClosed = false
      window.level = .floating
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      var pool: [LabLayerTextRow] = []
      var clipsRows = false
      let list = TimelineListView<Int>(rows: TimelineRows(
        height: { _, _ in 34 },
        make: { id, width in
          let row = pool.popLast() ?? LabLayerTextRow()
          row.clipsToBounds = clipsRows
          row.configure("row \(id)", width: width, scale: scale)
          return row
        },
        recycle: { _, view in if let row = view as? LabLayerTextRow { pool.append(row) } }
      ))
      list.frame = window.contentView!.bounds
      window.contentView!.addSubview(list)
      list.layoutSubtreeIfNeeded()
      list.apply(TimelineTransaction(
        rows: Array(0 ..< 300), coverage: TimelineCoverage(reachesOldest: true, reachesNewest: true), scroll: .latest
      ))
      await b.frames(6)

      var parking = false
      var moving = false
      struct Tally { var frames = 0, parked = 0, labelWorst = 0, layerWorst = 0, labelFrames = 0, layerFrames = 0, visibleEmpty = 0 }
      var tally = Tally()
      let before = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_000_000) { _, _ in
        MainActor.assumeIsolated {
          guard let layer = list.content.layer else { return }
          let held = (layer.animation(forKey: "timeline.follow") as? CABasicAnimation)?.fromValue as? CGFloat ?? 0
          moving = abs(held) > 0.0001
          guard parking, moving else { return }
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          var bounds = list.content.bounds
          bounds.origin.y += held
          list.content.bounds = bounds
          layer.removeAnimation(forKey: "timeline.follow")
          CATransaction.commit()
          tally.parked += 1
        }
      }
      let after = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { _, _ in
        MainActor.assumeIsolated {
          guard moving else { return }
          var labels = 0
          var layers = 0
          for (id, view) in list.placedViews {
            guard let row = view as? LabLayerTextRow, let shown = list.presentedFrame(for: id),
                  shown.maxY > 0, shown.minY < list.bounds.height else { continue }
            if !row.label.showsItsText { labels += 1 }
            if !row.textLayer.showsItsText { layers += 1 }
            if row.label.visibleRect.isEmpty { tally.visibleEmpty += 1 }
          }
          tally.frames += 1
          tally.labelWorst = max(tally.labelWorst, labels)
          tally.layerWorst = max(tally.layerWorst, layers)
          if labels > 0 { tally.labelFrames += 1 }
          if layers > 0 { tally.layerFrames += 1 }
          CATransaction.flush()
        }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), before, .commonModes)
      CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
      defer {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), before, .commonModes)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), after, .commonModes)
      }
      for (mode, target, clips) in [("model follows", 10, false), ("model parked", 290, false), ("model follows, clipsToBounds", 10, true), ("model parked, clipsToBounds", 290, true)] {
        parking = mode.hasPrefix("model parked")
        list.content.clipsToBounds = clips
        clipsRows = clips
        for (_, view) in list.placedViews { view.clipsToBounds = clips }
        for row in pool { row.clipsToBounds = clips }
        tally = Tally()
        list.apply(TimelineTransaction(scroll: .to(target, .center), timing: .standard))
        await b.wait(1.2)
        parking = false
        c.note("\(mode): \(tally.frames) moving frames (\(tally.parked) parked); undrawn on screen worst NSTextField \(tally.labelWorst) (\(tally.labelFrames) frames), layer \(tally.layerWorst) (\(tally.layerFrames) frames); label visibleRect empty \(tally.visibleEmpty)")
        c.atLeast("\(mode): moving frames", Double(tally.frames), 5, unit: "")
        c.near("\(mode): worst undrawn layer-text rows on screen", Double(tally.layerWorst), 0, within: 0)
        if parking {
          c.that("\(mode): parked every moving frame", tally.parked >= tally.frames - 1)
        } else {
          c.near("\(mode): worst undrawn NSTextField rows", Double(tally.labelWorst), 0, within: 0)
        }
        await b.frames(4)
      }
    }
  }

  @MainActor static var debugNote = ""

  struct ParkResult {
    var rows: Int
    var labelsDrawn: Int
    var layersDrawn: Int
    var layersWithContents: Int
    var visibleRectEmpty: Int
    var stayedParked: Bool
    var summary: String {
      "\(rows) rows on screen; NSTextField drew the new text in \(labelsDrawn), the layer in \(layersDrawn) (contents \(layersWithContents)); AppKit visible rect empty for \(visibleRectEmpty); model stayed parked \(stayedParked)"
    }
  }

  /// Moves `content`'s bounds origin 5,000 pt away (the model) while an additive animation shows it where it was
  /// (the screen), reconfigures every row with new text, waits three frames and counts what drew.
  @MainActor
  static func parkAndReconfigure(content: NSView, rows: [NSView], width: CGFloat, scale: CGFloat, b: Bench, inLayout: Bool = false) async -> ParkResult {
    let distance: CGFloat = 5000
    guard let layer = content.layer else { return ParkResult(rows: 0, labelsDrawn: 0, layersDrawn: 0, layersWithContents: 0, visibleRectEmpty: 0, stayedParked: false) }
    let shown = content.bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var parked = shown
    parked.origin.y += distance
    content.bounds = parked
    let hold = CABasicAnimation(keyPath: "bounds.origin.y")
    hold.fromValue = -distance
    hold.toValue = -distance
    hold.isAdditive = true
    hold.duration = 1
    hold.repeatCount = .infinity
    hold.isRemovedOnCompletion = false
    hold.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - 1
    hold.fillMode = .both
    layer.add(hold, forKey: "lab.park")
    CATransaction.commit()
    await b.frames(2)
    let onScreen = rows.compactMap { $0 as? LabLayerTextRow }.filter { $0.frame.maxY > shown.minY && $0.frame.minY < shown.maxY }
    let reconfigure = { for (i, row) in onScreen.enumerated() { row.configure("parked \(i) second", width: width, scale: scale) } }
    if inLayout, let content = content as? FlippedLabView {
      content.onLayout = reconfigure
      content.needsLayout = true
    } else {
      reconfigure()
    }
    await b.frames(3)
    let stayed = abs(content.bounds.origin.y - parked.origin.y) < 0.5
    if let first = onScreen.first {
      debugNote = "content bounds \(content.bounds) visible \(content.visibleRect) clips \(content.clipsToBounds); row in content \(first.convert(first.bounds, to: content)) in window \(first.convert(first.bounds, to: nil)); label visible \(first.label.visibleRect)"
    }
    let result = ParkResult(
      rows: onScreen.count,
      labelsDrawn: onScreen.filter(\.label.showsItsText).count,
      layersDrawn: onScreen.filter(\.textLayer.showsItsText).count,
      layersWithContents: onScreen.filter { $0.textLayer.contents != nil }.count,
      visibleRectEmpty: onScreen.filter { $0.label.visibleRect.isEmpty }.count,
      stayedParked: stayed
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.removeAnimation(forKey: "lab.park")
    content.bounds = shown
    CATransaction.commit()
    return result
  }
}

final class FlippedLabView: NSView {
  override var isFlipped: Bool { true }
  var onLayout: (() -> Void)?
  override func layout() {
    super.layout()
    onLayout?()
    onLayout = nil
  }
}
