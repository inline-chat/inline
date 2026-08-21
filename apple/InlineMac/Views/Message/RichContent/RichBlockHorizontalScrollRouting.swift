import AppKit

@MainActor
protocol RichBlockHorizontalScrollSurface: AnyObject {
  func consumeHorizontalScroll(_ event: NSEvent) -> Bool
}
