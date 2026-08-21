import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import InlineMacUI

@Suite("Inline tooltip", .serialized)
struct InlineTooltipTests {
  @Test("Shortcut keycaps use conventional modifier order")
  func shortcutKeycapOrder() {
    let shortcut = InlineTooltipShortcut(
      "n",
      modifiers: [.command, .shift, .option, .control]
    )

    #expect(shortcut.keycapLabels == ["⌃", "⌥", "⇧", "⌘", "N"])
  }

  @Test("Automatic placement prefers above and centers on the target")
  func automaticPlacementAbove() {
    let frame = InlineTooltipGeometry.frame(
      anchorFrame: CGRect(x: 120, y: 100, width: 40, height: 28),
      tooltipSize: CGSize(width: 100, height: 28),
      visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
      placement: .automatic
    )

    #expect(frame == CGRect(x: 90, y: 134, width: 100, height: 28))
  }

  @Test("Automatic placement falls below near the top edge")
  func automaticPlacementBelow() {
    let frame = InlineTooltipGeometry.frame(
      anchorFrame: CGRect(x: 120, y: 270, width: 40, height: 24),
      tooltipSize: CGSize(width: 100, height: 28),
      visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
      placement: .automatic
    )

    #expect(frame == CGRect(x: 90, y: 236, width: 100, height: 28))
  }

  @Test("Placement clamps the pill inside the visible screen")
  func placementClampsToScreen() {
    let frame = InlineTooltipGeometry.frame(
      anchorFrame: CGRect(x: 1, y: 100, width: 12, height: 20),
      tooltipSize: CGSize(width: 120, height: 28),
      visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
      placement: .above
    )

    #expect(frame.origin == CGPoint(x: 8, y: 126))
  }

  @Test("Preferred side placements stay centered on the target")
  func preferredSidePlacements() {
    let anchor = CGRect(x: 120, y: 100, width: 40, height: 28)
    let tooltip = CGSize(width: 100, height: 28)
    let screen = CGRect(x: 0, y: 0, width: 400, height: 300)

    let rightFrame = InlineTooltipGeometry.frame(
      anchorFrame: anchor,
      tooltipSize: tooltip,
      visibleFrame: screen,
      placement: .right
    )
    let leftFrame = InlineTooltipGeometry.frame(
      anchorFrame: anchor,
      tooltipSize: tooltip,
      visibleFrame: screen,
      placement: .left
    )
    let belowFrame = InlineTooltipGeometry.frame(
      anchorFrame: anchor,
      tooltipSize: tooltip,
      visibleFrame: screen,
      placement: .below
    )

    #expect(rightFrame.origin == CGPoint(x: 166, y: 100))
    #expect(leftFrame.origin == CGPoint(x: 14, y: 100))
    #expect(belowFrame.origin == CGPoint(x: 90, y: 66))
  }

  @Test("Transparent rendering bleed does not increase the visible target gap")
  func renderingBleedPlacement() {
    let anchor = CGRect(x: 120, y: 100, width: 40, height: 28)
    let tooltip = CGSize(width: 100, height: 46)
    let frame = InlineTooltipGeometry.frame(
      anchorFrame: anchor,
      tooltipSize: tooltip,
      visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
      placement: .above,
      renderingInset: 12
    )

    #expect(frame == CGRect(x: 90, y: 122, width: 100, height: 46))
    #expect(frame.minY + 12 == anchor.maxY + InlineTooltipGeometry.targetSpacing)
  }

  @Test("A preferred side falls back to its opposite before clamping")
  func preferredSideFallback() {
    let anchor = CGRect(x: 120, y: 10, width: 40, height: 28)
    let frame = InlineTooltipGeometry.frame(
      anchorFrame: anchor,
      tooltipSize: CGSize(width: 100, height: 46),
      visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
      placement: .below,
      renderingInset: 12
    )

    #expect(frame == CGRect(x: 90, y: 32, width: 100, height: 46))
    #expect(frame.minY + 12 == anchor.maxY + InlineTooltipGeometry.targetSpacing)
  }

  @Test("Cursor placement keeps glass clear of the pointer and flips at screen edges")
  func cursorPlacement() {
    let screen = CGRect(x: 0, y: 0, width: 400, height: 300)
    let tooltip = CGSize(width: 100, height: 46)
    let centered = InlineTooltipGeometry.frame(
      anchorFrame: CGRect(x: 150, y: 150, width: 0, height: 0),
      tooltipSize: tooltip,
      visibleFrame: screen,
      placement: .cursor,
      renderingInset: 12
    )
    let lowerRight = InlineTooltipGeometry.frame(
      anchorFrame: CGRect(x: 380, y: 20, width: 0, height: 0),
      tooltipSize: tooltip,
      visibleFrame: screen,
      placement: .cursor,
      renderingInset: 12
    )

    #expect(centered == CGRect(x: 146, y: 108, width: 100, height: 46))
    #expect(centered.minX + 12 == 150 + InlineTooltipGeometry.cursorSpacing)
    #expect(centered.maxY - 12 == 150 - InlineTooltipGeometry.cursorSpacing)
    #expect(lowerRight == CGRect(x: 284, y: 16, width: 100, height: 46))
  }

  @Test("Pill content keeps full text, padding, and centered keycaps")
  @MainActor
  func pillContentLayout() throws {
    let bubble = InlineTooltipBubbleView(frame: .zero)
    bubble.update(InlineTooltipResolvedContent(text: "Search", shortcut: .command("K")))
    bubble.frame.size = bubble.intrinsicContentSize
    bubble.layoutSubtreeIfNeeded()

    let searchField = try #require(bubble.descendantTextField(with: "Search"))
    let commandField = try #require(bubble.descendantTextField(with: "⌘"))
    let keyField = try #require(bubble.descendantTextField(with: "K"))
    let searchFrame = searchField.convert(searchField.bounds, to: bubble)
    let commandFrame = commandField.convert(commandField.bounds, to: bubble)
    let keyFrame = keyField.convert(keyField.bounds, to: bubble)
    let surfaceView = try #require(bubble.subviews.first)
    let commandKeycap = try #require(commandField.superview)
    let commandKeycapFrame = commandKeycap.convert(commandKeycap.bounds, to: bubble)

    #expect(bubble.intrinsicContentSize.height == 46)
    #expect(surfaceView.frame.height == 22)
    #expect(surfaceView.frame.minX == 12)
    #expect(surfaceView.frame.maxX == bubble.bounds.maxX - 12)
    #expect(searchFrame.minX >= 19)
    #expect(searchField.font == NSFont.systemFont(ofSize: 11, weight: .regular))
    #expect(commandField.font == NSFont.systemFont(ofSize: 11, weight: .regular))
    #expect(keyField.font == NSFont.systemFont(ofSize: 11, weight: .regular))
    #expect(searchField.frame.width >= ceil(searchField.cell?.cellSize.width ?? 0))
    #expect(searchFrame.maxX < commandFrame.minX)
    #expect(commandFrame.maxX < keyFrame.minX)
    #expect(abs(searchFrame.midY - commandFrame.midY) <= 1)
    #expect(abs(commandFrame.midY - keyFrame.midY) <= 1)
    #expect(abs(commandKeycapFrame.midY - surfaceView.frame.midY) <= 0.5)
    #expect(keyFrame.maxX <= bubble.bounds.maxX - 19)
    #expect(commandKeycap.frame.size == CGSize(width: 16, height: 16))
    let commandLeftInset = commandField.frame.minX
    let commandRightInset = commandKeycap.bounds.maxX - commandField.frame.maxX
    #expect(abs(commandLeftInset - commandRightInset) <= 0.5)

    if #available(macOS 26.0, *) {
      let glassView = try #require(surfaceView as? NSGlassEffectView)
      #expect(glassView.style == .clear)
      #expect(glassView.tintColor == nil)
      #expect(glassView.cornerRadius == 11)
    }
    #expect(bubble.layer?.shadowOpacity == 0.14)
    #expect(bubble.layer?.shadowRadius == 7)
    #expect(bubble.layer?.shadowOffset == CGSize(width: 0, height: -2))
    #expect(bubble.layer?.shadowPath != nil)
  }

  @Test("SwiftUI exposes the localized tooltip modifier")
  @MainActor
  func swiftUIModifierCompiles() {
    let view = Text("Target")
      .inlineTooltip("New thread", shortcut: .command("N"))

    _ = view
  }

  @Test("Explicit AppKit and SwiftUI attachments install active tracking")
  @MainActor
  func tooltipAttachmentsInstall() {
    let appKitTarget = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 28))
    appKitTarget.setInlineTooltip("Target")
    let trackingArea = appKitTarget.trackingAreas.first
    #expect(trackingArea?.options.contains(.activeAlways) == true)
    #expect(trackingArea?.options.contains(.activeInActiveApp) == false)

    let host = tooltipHost()
    #expect(host.containsInlineTooltipAnchor)

    appKitTarget.removeInlineTooltip()
    #expect(appKitTarget.trackingAreas.isEmpty)
  }

  @Test("The manager reuses one non-activating panel between targets")
  @MainActor
  func managerReusesPanel() async throws {
    let manager = InlineTooltipManager.shared
    manager.hideImmediately()

    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 440, height: 180),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let firstTarget = NSButton(frame: CGRect(x: 20, y: 40, width: 40, height: 28))
    let secondTarget = NSButton(frame: CGRect(x: 340, y: 40, width: 40, height: 28))
    window.contentView?.addSubview(firstTarget)
    window.contentView?.addSubview(secondTarget)

    manager.showImmediately(
      InlineTooltipContent("Search", shortcut: .command("K")),
      anchoredTo: firstTarget,
      placement: .automatic
    )

    let firstPanel = try #require(window.childWindows?.first)
    let firstFrame = firstPanel.frame
    #expect(window.childWindows?.count == 1)
    #expect(firstPanel is NSPanel)
    #expect(firstPanel.ignoresMouseEvents)
    #expect(!firstPanel.canBecomeKey)
    #expect(!firstPanel.hasShadow)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(firstPanel.isVisible)
    #expect(window.childWindows?.count == 1)

    manager.hide(anchoredTo: firstTarget)
    try await Task.sleep(for: .milliseconds(250))
    #expect(firstPanel.isVisible)
    #expect(window.childWindows?.count == 1)

    manager.show(
      InlineTooltipContent("New"),
      anchoredTo: secondTarget,
      placement: .automatic
    )

    let secondPanel = try #require(window.childWindows?.first)
    #expect(window.childWindows?.count == 1)
    #expect(secondPanel === firstPanel)
    #expect(secondPanel.frame != firstFrame)

    let expectedBubble = InlineTooltipBubbleView(frame: .zero)
    expectedBubble.update(InlineTooltipResolvedContent(text: "New", shortcut: nil))
    #expect(abs(secondPanel.frame.width - expectedBubble.intrinsicContentSize.width) <= 0.5)
    #expect(abs(secondPanel.frame.height - expectedBubble.intrinsicContentSize.height) <= 0.5)

    let stableFrame = secondPanel.frame
    secondTarget.frame.origin.x -= 80
    manager.show(
      InlineTooltipContent("New"),
      anchoredTo: secondTarget,
      placement: .automatic
    )
    #expect(secondPanel.frame == stableFrame)

    let subsection = CGRect(x: 6, y: 5, width: 12, height: 10)
    manager.showImmediately(
      InlineTooltipContent(verbatim: "https://inline.chat"),
      anchoredTo: secondTarget,
      anchorRect: subsection,
      placement: .above
    )
    let subsectionInWindow = secondTarget.convert(subsection, to: nil)
    let subsectionOnScreen = window.convertToScreen(subsectionInWindow)
    #expect(abs(secondPanel.frame.midX - subsectionOnScreen.midX) <= 0.5)

    try sendLeftMouseDown(to: window)
    #expect((window.childWindows ?? []).isEmpty)
    #expect(!secondPanel.isVisible)

    window.orderOut(nil)
  }

  @Test("Removing an AppKit target dismisses its tooltip immediately")
  @MainActor
  func targetRemovalDismissesTooltip() throws {
    let manager = InlineTooltipManager.shared
    manager.hideImmediately()

    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let target = NSView(frame: CGRect(x: 80, y: 40, width: 40, height: 28))
    window.contentView?.addSubview(target)
    target.setInlineTooltip("Target")
    manager.showImmediately(
      InlineTooltipContent("Target"),
      anchoredTo: target,
      placement: .automatic
    )

    let panel = try #require(window.childWindows?.first)
    #expect(panel.isVisible)

    target.removeFromSuperview()

    #expect((window.childWindows ?? []).isEmpty)
    #expect(!panel.isVisible)
    window.orderOut(nil)
  }

  @Test("A click completes an in-progress fade immediately")
  @MainActor
  func clickDuringFadeDismissesImmediately() throws {
    let manager = InlineTooltipManager.shared
    manager.hideImmediately()

    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let target = NSView(frame: CGRect(x: 80, y: 40, width: 40, height: 28))
    window.contentView?.addSubview(target)
    manager.showImmediately(
      InlineTooltipContent("Target"),
      anchoredTo: target,
      placement: .automatic
    )

    let panel = try #require(window.childWindows?.first)
    manager.hide()
    #expect(panel.isVisible)

    try sendLeftMouseDown(to: window)

    #expect((window.childWindows ?? []).isEmpty)
    #expect(!panel.isVisible)
    window.orderOut(nil)
  }

  @Test("First hover waits longer and immediate handoff expires after 300 milliseconds")
  @MainActor
  func tooltipTiming() async throws {
    let manager = InlineTooltipManager.shared
    manager.hideImmediately()

    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 240, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let target = NSView(frame: CGRect(x: 80, y: 40, width: 40, height: 28))
    window.contentView?.addSubview(target)

    manager.show(InlineTooltipContent("Cancelled"), anchoredTo: target)
    try await Task.sleep(for: .milliseconds(300))
    try sendLeftMouseDown(to: window)
    try await Task.sleep(for: .milliseconds(1_000))
    #expect((window.childWindows ?? []).isEmpty)

    manager.show(InlineTooltipContent("Delayed"), anchoredTo: target)
    try await Task.sleep(for: .milliseconds(1_000))
    #expect((window.childWindows ?? []).isEmpty)

    try await Task.sleep(for: .milliseconds(350))
    let panel = try #require(window.childWindows?.first)
    #expect(panel.isVisible)

    manager.hide(anchoredTo: target)
    try await Task.sleep(for: .milliseconds(200))
    #expect(panel.isVisible)

    try await Task.sleep(for: .milliseconds(400))
    #expect((window.childWindows ?? []).isEmpty)
    #expect(!panel.isVisible)

    let nextTarget = NSView(frame: CGRect(x: 150, y: 40, width: 40, height: 28))
    window.contentView?.addSubview(nextTarget)
    manager.show(InlineTooltipContent("After grace"), anchoredTo: nextTarget)
    try await Task.sleep(for: .milliseconds(100))
    #expect((window.childWindows ?? []).isEmpty)
    manager.hide(anchoredTo: nextTarget)

    manager.hideImmediately()
    window.orderOut(nil)
  }

  @MainActor
  private func sendLeftMouseDown(to window: NSWindow) throws {
    let click = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 0
    ))
    NSApp.sendEvent(click)
  }

  @MainActor
  private func tooltipHost() -> NSView {
    let host = NSHostingView(rootView: Text("Target").inlineTooltip("Target"))
    host.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
    host.layoutSubtreeIfNeeded()
    return host
  }
}

private extension NSView {
  var containsInlineTooltipAnchor: Bool {
    self is InlineTooltipAnchorView || subviews.contains(where: \.containsInlineTooltipAnchor)
  }

  func descendantTextField(with value: String) -> NSTextField? {
    if let textField = self as? NSTextField, textField.stringValue == value {
      return textField
    }
    return subviews.lazy.compactMap { $0.descendantTextField(with: value) }.first
  }
}
