import SwiftUI

/// Marks app-defined toolbar content whose required dependencies are passed explicitly.
///
/// UIKit can detach and rematerialize SwiftUI toolbar views while foregrounding. Types that
/// conform here are audited by the Apple crash-pattern check and must not require injected
/// app-owned objects from the SwiftUI environment.
protocol RehostSafeToolbarContent {}
