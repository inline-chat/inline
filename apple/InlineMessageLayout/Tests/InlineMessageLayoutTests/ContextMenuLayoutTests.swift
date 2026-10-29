import CoreGraphics
import Testing
@testable import InlineMessageLayout

@Suite("Context menu layout")
struct ContextMenuLayoutTests {
  /// An iPhone 15 screen: 47-point top and 34-point bottom safe area. Expected values are
  /// written out: `#expect` type-checks arithmetic on bare literals on its own, so `== 47 + 8`
  /// fails on CI even when the frame is exactly 55.
  let viewport = CGSize(width: 390, height: 844)
  let safe = ContextMenuLayout.Insets(top: 47, bottom: 34)
  let menu = CGSize(width: 250, height: 300)

  private func plan(
    source: CGRect,
    menu: CGSize? = nil,
    accessory: CGSize? = nil,
    alignment: ContextMenuLayout.Alignment = .left,
    viewport: CGSize? = nil,
    safe: ContextMenuLayout.Insets? = nil
  ) -> ContextMenuLayout.Result {
    ContextMenuLayout.plan(.init(
      viewport: viewport ?? self.viewport,
      safeInsets: safe ?? self.safe,
      source: source,
      menuSize: menu ?? self.menu,
      accessorySize: accessory,
      alignment: alignment
    ))
  }

  @Test("A bubble with room below stays where it was, with the menu under its leading edge")
  func staysInPlace() {
    let result = plan(source: CGRect(x: 16, y: 400, width: 200, height: 60))
    #expect(result.preview == CGRect(x: 16, y: 400, width: 200, height: 60))
    #expect(result.menu == CGRect(x: 16, y: 468, width: 250, height: 300))
    #expect(!result.isScrollable)
    #expect(result.contentOffsetY == 0)
    #expect(result.contentSize == viewport)
    #expect(result.menuAnchor == CGPoint(x: 0, y: 0))
  }

  @Test("An outgoing bubble lines the menu up with its trailing edge")
  func outgoingAlignsRight() {
    let result = plan(source: CGRect(x: 174, y: 400, width: 200, height: 60), alignment: .right)
    #expect(result.menu.maxX == result.preview.maxX)
    #expect(result.menu.minX == 124)
    #expect(result.menuAnchor == CGPoint(x: 1, y: 0))
  }

  @Test("A bubble near the bottom moves up until the menu clears the bottom inset")
  func movesUpNearBottom() {
    let result = plan(source: CGRect(x: 16, y: 700, width: 200, height: 60))
    // 844 - 34 safe - 10 inset = 800 for the menu's bottom.
    #expect(result.menu.maxY == 800)
    // 800 less the 300-point menu, 8 of spacing and the 60-point bubble.
    #expect(result.preview.minY == 432)
    #expect(!result.isScrollable)
  }

  @Test("A bubble near the top moves down to leave room for the reaction bar")
  func movesDownForAccessory() throws {
    let accessory = CGSize(width: 300, height: 52)
    let result = plan(source: CGRect(x: 16, y: 30, width: 200, height: 60), accessory: accessory)
    let bar = try #require(result.accessory)
    #expect(bar.minY == 55) // 47 safe area + 8 inset
    #expect(result.preview.minY == bar.maxY + 8)
    #expect(bar.minX == 16)
    #expect(bar.size == accessory)
  }

  @Test("A message taller than the screen pins its top and opens scrolled to the menu")
  func tallMessageScrolls() {
    let source = CGRect(x: 16, y: 100, width: 300, height: 900)
    let result = plan(source: source)
    #expect(result.isScrollable)
    #expect(result.preview.minY == 55) // 47 safe area + 8 inset
    #expect(result.menu.minY == result.preview.maxY + 8)
    #expect(result.contentSize.height == result.menu.maxY + 10 + 34)
    #expect(result.contentOffsetY == result.contentSize.height - viewport.height)
    // At the initial offset the menu ends at the bottom inset.
    #expect(result.menu.maxY - result.contentOffsetY == 800)
    #expect(result.contentRect(fromViewport: source).minY == source.minY + result.contentOffsetY)
  }

  @Test("Bubbles and menus stay inside the side insets")
  func clampsHorizontally() {
    let shifted = plan(source: CGRect(x: 300, y: 400, width: 200, height: 60))
    #expect(shifted.preview.maxX == 378) // 390 less the 12-point side inset

    let wide = plan(source: CGRect(x: 16, y: 400, width: 200, height: 60), menu: CGSize(width: 500, height: 200))
    #expect(wide.menu.width == 366) // 390 less both side insets
    #expect(wide.menu.minX == 12)

    let right = plan(source: CGRect(x: 16, y: 400, width: 100, height: 60), alignment: .right)
    #expect(right.menu.minX == 12)
  }

  @Test("With a keyboard, the column fits in the viewport above it")
  func fitsAboveKeyboard() {
    let result = plan(
      source: CGRect(x: 16, y: 380, width: 200, height: 60),
      viewport: CGSize(width: 390, height: 500),
      safe: ContextMenuLayout.Insets(top: 47)
    )
    #expect(result.menu.maxY == 490)
    #expect(!result.isScrollable)
    #expect(result.contentSize.height == 500)
  }

  @Test("Frames land on the pixel grid")
  func pixelAligned() throws {
    let result = plan(source: CGRect(x: 16.1, y: 400.37, width: 200.2, height: 60.11), accessory: CGSize(width: 280.5, height: 52))
    let grid = PixelGrid(scale: 3)
    #expect(grid.isAligned(result.preview))
    #expect(grid.isAligned(result.menu))
    let bar = try #require(result.accessory)
    #expect(grid.isAligned(bar))
  }
}
