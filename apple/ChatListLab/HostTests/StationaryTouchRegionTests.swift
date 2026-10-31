import UIKit
import Testing
@testable import ChatListPhoneLab

@Suite @MainActor
struct StationaryTouchRegionTests {
  @Test func scrolledGutterUsesNativeBoundsCoordinates() {
    let parent = UIView(frame: .init(x: 0, y: 0, width: 400, height: 600))
    let scroll = UIScrollView(frame: .init(x: 0, y: 100, width: 400, height: 300))
    parent.addSubview(scroll)
    scroll.contentSize = .init(width: 400, height: 30_000)
    scroll.contentOffset.y = 24_000
    let finger = scroll.convert(CGPoint(x: 8, y: 250), from: parent)
    #expect(finger.y == 24_150)
    #expect(StationaryTouchRegion.contains(finger, in: scroll.bounds))
    // Negative control: the previous zero-origin gate rejected this real touch.
    #expect(!CGRect(origin: .zero, size: scroll.bounds.size).contains(finger))
    #expect(!StationaryTouchRegion.contains(.init(x: 17, y: finger.y), in: scroll.bounds))
    #expect(!StationaryTouchRegion.contains(.init(x: 8, y: 23_999), in: scroll.bounds))
  }
}
