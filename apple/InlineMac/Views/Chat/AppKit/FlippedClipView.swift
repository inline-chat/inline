import AppKit

public final class FlippedClipView: NSClipView {
    override public var isFlipped: Bool { true }
}

public final class FlippedView: NSView {
    override public var isFlipped: Bool { true }
}

public final class FlippedCollectionView: NSCollectionView {
    override public var isFlipped: Bool { true }
}

public final class FlippedScrollView: NSScrollView {
    override public var isFlipped: Bool { true }
}
