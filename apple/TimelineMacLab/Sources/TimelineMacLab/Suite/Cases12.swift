import AppKit
import TimelineAppKit
import TimelineCore

// AppKit's drawing gate in the app's own window structure. Inline's main window is a SwiftUI NavigationSplitView: the
// chat pane sits in `_NSSplitViewItemViewWrapper` inside `NSSplitView`, and both clip (`clipsToBounds`). Does that
// clipping keep rows the list places beyond the pane's edges (its margins, and up to a screen ahead of a fling) from
// drawing until they come inside (design doc pitfall 11)? Measured 2026-11-26: no. Rows beyond the pane's edge draw
// when placed under the split view's own clipping, as with it off; the gate `Cases9` found needs a clipping view
// close to the rows (the content view or the rows themselves). Kept as a guard: if it fails, the split view started
// gating and the list's ahead rows can show blank.

extension SuiteCases {
  static var splitGate: [BehaviourCase] {
    [
      BehaviourCase(
        id: "draw.split-pane-gate", area: "Drawing",
        behaviour: "Rows placed beyond the edges of a split view's pane (the app's main window is a SwiftUI split view) draw when placed, under the split view's own clipping as with it off"
      ) { b, c in
        let scale = b.window.backingScaleFactor
        let rowHeight: CGFloat = 34
        for unclip in [false, true] {
          let window = NSWindow(
            contentRect: NSRect(origin: LabPlacement.origin, size: NSSize(width: 520, height: 500)),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
          )
          window.isReleasedWhenClosed = false
          window.level = .floating
          let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 500))
          window.contentView = root
          let split = NSSplitViewController()
          let side = NSViewController()
          side.view = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 500))
          let detail = NSViewController()
          let pane = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 500))
          detail.view = pane
          split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: side))
          split.addSplitViewItem(NSSplitViewItem(viewController: detail))
          split.view.frame = root.bounds
          split.view.autoresizingMask = [.width, .height]
          root.addSubview(split.view)
          window.orderFrontRegardless()
          await b.frames(3)

          // The list's stand-in: a layer-masked container (as `TimelineListView`), its flipped content, rows inside the
          // pane and rows placed below its bottom edge.
          let container = NSView(frame: pane.bounds)
          container.autoresizingMask = [.width, .height]
          container.wantsLayer = true
          container.layer?.masksToBounds = true
          let content = FlippedLabView(frame: container.bounds)
          content.wantsLayer = true
          container.addSubview(content)
          pane.addSubview(container)
          var clipping: [String] = []
          var view: NSView? = container.superview
          while let current = view, current !== root {
            if current.clipsToBounds {
              clipping.append(String(describing: type(of: current)))
              if unclip, !(current is NSClipView), !(current is NSScrollView) { current.clipsToBounds = false }
            }
            view = current.superview
          }
          var inside: [LabLayerTextRow] = []
          var beyond: [LabLayerTextRow] = []
          let height = pane.bounds.height
          for i in 0 ..< 16 {
            let row = LabLayerTextRow()
            let y = i < 8 ? CGFloat(i) * rowHeight : height + CGFloat(i - 8) * rowHeight
            row.frame = NSRect(x: 0, y: y, width: pane.bounds.width, height: rowHeight)
            row.configure("row \(i)", width: pane.bounds.width, scale: scale)
            content.addSubview(row)
            if i < 8 { inside.append(row) } else { beyond.append(row) }
          }
          await b.frames(4)
          let mode = unclip ? "pane unclipped" : "split view clipping"
          c.note("\(mode): clipping ancestors \(clipping)")
          let drawnInside = inside.filter(\.label.showsItsText).count
          let drawnBeyond = beyond.filter(\.label.showsItsText).count
          c.note("\(mode): NSTextField rows drawn inside the pane \(drawnInside)/\(inside.count), beyond its edge \(drawnBeyond)/\(beyond.count); layer text beyond \(beyond.filter(\.textLayer.showsItsText).count)/\(beyond.count)")
          c.near("\(mode): rows inside the pane drawn", Double(drawnInside), Double(inside.count), within: 0)
          c.near("\(mode): rows beyond the pane's edge drawn when placed", Double(drawnBeyond), Double(beyond.count), within: 0)
          if !unclip { c.that("\(mode): the split view clips the pane", !clipping.isEmpty) }
          window.orderOut(nil)
        }
      },
      BehaviourCase(
        id: "draw.margin-rows-redraw", area: "Drawing",
        behaviour: "A row the list placed in its margin beyond the window (rows placed ahead of a fling, a pooled row reused there) draws its new text when reconfigured there, before it comes on screen, when the text is drawn by Core Animation; AppKit-drawn text nested in a clipping view (a rounded bubble) waits until the row is in the window (found in the Dev app: a row came on screen with its bubble but no text)"
      ) { b, c in
        let scale = b.window.backingScaleFactor
        let window = NSWindow(
          contentRect: NSRect(origin: LabPlacement.origin, size: NSSize(width: 520, height: 600)),
          styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for bubbled in [false, true] {
          let kind = bubbled ? "text in a masked bubble (as BasicView)" : "text in the row"
          let list = TimelineListView<Int>(rows: TimelineRows(
            height: { _, _ in 34 },
            make: { id, width in
              let row = LabBubbleTextRow(bubbled: bubbled)
              row.configure("row \(id)", width: width, scale: scale)
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
          c.note("list clipsToBounds \(list.clipsToBounds), layer masksToBounds \(list.layer?.masksToBounds ?? false), mask layer \(list.layer?.mask != nil)")
          // Rows placed beyond the list's bounds (its margins), reconfigured there as a reused row is.
          let margin = list.placedViews.compactMap { $0.1 as? LabBubbleTextRow }.filter {
            let frame = $0.convert($0.bounds, to: list)
            return frame.maxY <= 0 || frame.minY >= list.bounds.height
          }
          c.atLeast("\(kind): rows placed in the margins", Double(margin.count), 1, unit: "")
          for (i, row) in margin.enumerated() { row.configure("reused \(i)", width: list.bounds.width, scale: scale) }
          await b.frames(4)
          let drawn = margin.filter(\.label.showsItsText).count
          let layersDrawn = margin.filter(\.textLayer.showsItsText).count
          c.note("\(kind): margin rows drawn by AppKit (NSTextField) \(drawn)/\(margin.count), by Core Animation (layer) \(layersDrawn)/\(margin.count)")
          c.near("\(kind): margin rows whose layer text drew", Double(layersDrawn), Double(margin.count), within: 0)
          // AppKit's drawing of a view nested in a clipping view stops at the window's edge (the known gate, measured
          // 0 of 6); outside any clipping view it draws.
          if !bubbled { c.near("\(kind): margin rows whose NSTextField drew", Double(drawn), Double(margin.count), within: 0) }
          list.removeFromSuperview()
        }
      },
    ]
  }
}

/// A row whose text sits in the row, or in a bubble that masks its rounded corners (as the app's `BasicView` does,
/// which AppKit reports as `clipsToBounds`).
final class LabBubbleTextRow: NSView {
  let label = LabLabel(labelWithString: "")
  /// The same text drawn by Core Animation, beside the field in the same container.
  let textLayer = LabTextLayer()
  private let bubble = NSView()
  override var isFlipped: Bool { true }

  init(bubbled: Bool) {
    super.init(frame: .zero)
    wantsLayer = true
    label.font = .systemFont(ofSize: 13)
    if bubbled {
      bubble.wantsLayer = true
      bubble.layer?.cornerRadius = 10
      bubble.layer?.masksToBounds = true
      bubble.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
      addSubview(bubble)
      bubble.addSubview(label)
      bubble.layer?.addSublayer(textLayer)
    } else {
      addSubview(label)
      layer?.addSublayer(textLayer)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(_ text: String, width: CGFloat, scale: CGFloat) {
    label.stringValue = text
    let half = max(40, width / 2 - 24)
    if label.superview === bubble {
      bubble.frame = NSRect(x: 12, y: 3, width: width - 24, height: 28)
      label.frame = NSRect(x: 8, y: 4, width: half - 16, height: 20)
      textLayer.frame = CGRect(x: half, y: 4, width: half - 16, height: 20)
    } else {
      label.frame = NSRect(x: 12, y: 6, width: half, height: 20)
      textLayer.frame = CGRect(x: half + 24, y: 6, width: half, height: 20)
    }
    textLayer.contentsScale = scale
    textLayer.configure(text, size: textLayer.bounds.size)
  }
}
