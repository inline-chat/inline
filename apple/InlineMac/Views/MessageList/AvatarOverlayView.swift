import AppKit
import InlineKit
import InlineUI

struct MessageAvatarOverlayItem {
  let stableId: Int64
  let userInfo: UserInfo
  let frame: CGRect
  var sticky: MessageAvatarOverlaySticky?
  let onClick: () -> Void
}

enum MessageAvatarStickyMode {
  case top
  case bottom
}

struct MessageAvatarOverlaySticky {
  let mode: MessageAvatarStickyMode
  let viewportFrame: CGRect
  let limitFrame: CGRect
  let viewportEdgeInset: CGFloat
}

struct MessageAvatarOverlaySyncStats {
  var active = 0
  var created = 0
  var reused = 0
  var recycled = 0
  var removed = 0
  var frameUpdates = 0
  var animatedFrameUpdates = 0
}

final class MessageAvatarOverlayView: NSView {
  private struct ReuseKey: Hashable {
    let userId: Int64
    let avatarIdentity: String?
    let size: Int

    init(userInfo: UserInfo, size: CGFloat) {
      userId = userInfo.user.id
      avatarIdentity = userInfo.stableAvatarIdentity
      self.size = Int((size * 100).rounded())
    }
  }

  private final class Entry {
    let view: UserAvatarView
    var reuseKey: ReuseKey
    var frame: CGRect = .null

    init(view: UserAvatarView, reuseKey: ReuseKey) {
      self.view = view
      self.reuseKey = reuseKey
    }
  }

  private var active: [Int64: Entry] = [:]
  private var pool: [ReuseKey: [UserAvatarView]] = [:]
  private var pooledViewCount = 0
  private let maxPooledViews = 64
  private let maxPooledViewsPerKey = 4

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @discardableResult
  func sync(
    items: [MessageAvatarOverlayItem],
    animate: Bool
  ) -> MessageAvatarOverlaySyncStats {
    var stats = MessageAvatarOverlaySyncStats(active: active.count)

    CATransaction.begin()
    CATransaction.setDisableActions(!animate)
    NSAnimationContext.beginGrouping()
    if !animate {
      NSAnimationContext.current.duration = 0
    }

    let nextIds = Set(items.map(\.stableId))
    var detached: [ReuseKey: [Entry]] = [:]
    let staleIds = active.keys.filter { !nextIds.contains($0) }
    for stableId in staleIds {
      guard let entry = active.removeValue(forKey: stableId) else { continue }
      stats.removed += 1
      detached[entry.reuseKey, default: []].append(entry)
    }

    for item in items {
      apply(item, detached: &detached, animate: animate, stats: &stats)
    }

    for entries in detached.values {
      for entry in entries {
        recycle(entry.view, key: entry.reuseKey)
        stats.recycled += 1
      }
    }

    NSAnimationContext.endGrouping()
    CATransaction.commit()

    return stats
  }

  func clearAvatars() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0

    for entry in active.values {
      recycle(entry.view, key: entry.reuseKey)
    }
    active.removeAll()

    NSAnimationContext.endGrouping()
    CATransaction.commit()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0 else { return nil }

    for view in subviews.reversed() {
      guard !view.isHidden, view.alphaValue > 0, view.frame.contains(point) else { continue }
      let localPoint = view.convert(point, from: self)
      if let hit = view.hitTest(localPoint) {
        return hit
      }
    }

    return nil
  }

  private func apply(
    _ item: MessageAvatarOverlayItem,
    detached: inout [ReuseKey: [Entry]],
    animate: Bool,
    stats: inout MessageAvatarOverlaySyncStats
  ) {
    guard item.frame.width > 0, item.frame.height > 0 else {
      if let entry = active.removeValue(forKey: item.stableId) {
        recycle(entry.view, key: entry.reuseKey)
        stats.removed += 1
        stats.recycled += 1
      }
      return
    }

    let avatarSize = max(item.frame.width, item.frame.height)
    let key = ReuseKey(userInfo: item.userInfo, size: avatarSize)
    let entry: Entry
    let canAnimateFrame: Bool
    if let current = active[item.stableId] {
      current.view.update(userInfo: item.userInfo, size: avatarSize)
      current.reuseKey = key
      entry = current
      canAnimateFrame = animate
    } else {
      if var entries = detached[key], let reused = entries.popLast() {
        if entries.isEmpty {
          detached.removeValue(forKey: key)
        } else {
          detached[key] = entries
        }
        reused.view.update(userInfo: item.userInfo, size: avatarSize)
        reused.reuseKey = key
        entry = reused
        stats.reused += 1
      } else {
        let view = dequeueAvatar(for: item.userInfo, key: key, size: avatarSize)
        addSubview(view)
        entry = Entry(view: view, reuseKey: key)
        stats.created += 1
      }
      active[item.stableId] = entry
      canAnimateFrame = false
    }

    entry.view.acceptsMouseInteraction = true
    entry.view.onClick = item.onClick
    let frame = resolvedFrame(for: item)
    guard entry.frame != frame else { return }
    entry.frame = frame
    stats.frameUpdates += 1
    if canAnimateFrame {
      stats.animatedFrameUpdates += 1
      entry.view.animator().frame = frame
    } else {
      entry.view.frame = frame
    }
  }

  private func resolvedFrame(for item: MessageAvatarOverlayItem) -> CGRect {
    var frame = pixelAligned(item.frame)
    guard let sticky = item.sticky else { return frame }

    switch sticky.mode {
    case .bottom:
      let stickyY = sticky.viewportFrame.maxY - sticky.viewportEdgeInset - frame.height
      frame.origin.y = clamped(stickyY, min: sticky.limitFrame.minY, max: frame.origin.y)

    case .top:
      let stickyY = sticky.viewportFrame.minY + sticky.viewportEdgeInset
      frame.origin.y = clamped(stickyY, min: frame.origin.y, max: sticky.limitFrame.maxY - frame.height)
    }

    return pixelAligned(frame)
  }

  private func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    guard minValue <= maxValue else { return maxValue }
    return min(Swift.max(value, minValue), maxValue)
  }

  private func pixelAligned(_ rect: CGRect) -> CGRect {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard scale > 0 else { return rect }

    func align(_ value: CGFloat) -> CGFloat {
      (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    return CGRect(
      x: align(rect.origin.x),
      y: align(rect.origin.y),
      width: align(rect.width),
      height: align(rect.height)
    )
  }

  private func dequeueAvatar(for userInfo: UserInfo, key: ReuseKey, size: CGFloat) -> UserAvatarView {
    if var views = pool[key], let view = views.popLast() {
      pooledViewCount = max(0, pooledViewCount - 1)
      if views.isEmpty {
        pool.removeValue(forKey: key)
      } else {
        pool[key] = views
      }
      view.update(userInfo: userInfo, size: size)
      return view
    }

    let view = UserAvatarView(userInfo: userInfo, size: size)
    view.translatesAutoresizingMaskIntoConstraints = true
    return view
  }

  private func recycle(_ view: UserAvatarView, key: ReuseKey) {
    view.onClick = nil
    view.removeFromSuperview()

    var views = pool[key] ?? []
    guard pooledViewCount < maxPooledViews else { return }
    guard views.count < maxPooledViewsPerKey else { return }
    views.append(view)
    pooledViewCount += 1
    pool[key] = views
  }
}
