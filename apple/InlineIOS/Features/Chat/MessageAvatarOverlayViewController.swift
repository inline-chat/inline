import InlineKit
import UIKit

enum MessageAvatarOverlayConfig {
  static let enabled = true
  static let avatarSize: CGFloat = 28
  static let viewportEdgeInset: CGFloat = 0
  static let maxPooledViews = 32
  static let maxPooledViewsPerKey = 3
}

struct MessageAvatarOverlayItem {
  let stableId: Int64
  let userInfo: UserInfo
  let frame: CGRect
  let viewportFrame: CGRect
  let limitFrame: CGRect
  let onTap: () -> Void
}

final class MessageAvatarOverlayViewController: UIViewController {
  private let overlayView = MessageAvatarOverlayView()
  private var constraints: [NSLayoutConstraint] = []
  private weak var collectionView: UICollectionView?

  var isAttached: Bool {
    view.superview != nil
  }

  override func loadView() {
    view = overlayView
  }

  func attach(over collectionView: UICollectionView, in parent: UIViewController?) {
    guard MessageAvatarOverlayConfig.enabled else {
      detach()
      return
    }

    guard let parent, let hostView = collectionView.superview else { return }
    if let superview = view.superview,
       self.collectionView === collectionView,
       self.parent === parent,
       superview === hostView
    {
      return
    }

    detach()

    self.collectionView = collectionView
    parent.addChild(self)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.isOpaque = false
    view.layer.zPosition = collectionView.layer.zPosition
    hostView.insertSubview(view, aboveSubview: collectionView)

    constraints = [
      view.topAnchor.constraint(equalTo: collectionView.topAnchor),
      view.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
      view.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
    ]
    NSLayoutConstraint.activate(constraints)
    didMove(toParent: parent)
  }

  func detach() {
    clear()

    if parent != nil {
      willMove(toParent: nil)
    }
    NSLayoutConstraint.deactivate(constraints)
    constraints.removeAll()
    view.removeFromSuperview()
    removeFromParent()
    collectionView = nil
  }

  func sync(items: [MessageAvatarOverlayItem], animate: Bool) {
    overlayView.sync(items: items, animate: animate)
  }

  func clear() {
    overlayView.clearAvatars()
  }
}

private final class MessageAvatarOverlayView: UIView {
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

  private final class TapTarget: NSObject {
    var onTap: (() -> Void)?

    @objc func tap() {
      onTap?()
    }
  }

  private final class Entry {
    let view: UserAvatarView
    let tapTarget = TapTarget()
    var reuseKey: ReuseKey
    var frame: CGRect = .null

    init(view: UserAvatarView, reuseKey: ReuseKey) {
      self.view = view
      self.reuseKey = reuseKey

      let tap = UITapGestureRecognizer(target: tapTarget, action: #selector(TapTarget.tap))
      view.addGestureRecognizer(tap)
      view.isUserInteractionEnabled = true
    }
  }

  private var active: [Int64: Entry] = [:]
  private var pool: [ReuseKey: [Entry]] = [:]
  private var pooledViewCount = 0

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01 else { return nil }

    for view in subviews.reversed() {
      guard !view.isHidden, view.alpha > 0.01, view.frame.contains(point) else { continue }
      let localPoint = view.convert(point, from: self)
      if let hit = view.hitTest(localPoint, with: event) {
        return hit
      }
    }

    return nil
  }

  func sync(items: [MessageAvatarOverlayItem], animate: Bool) {
    let nextIds = Set(items.map(\.stableId))
    let staleIds = active.keys.filter { !nextIds.contains($0) }

    CATransaction.begin()
    CATransaction.setDisableActions(!animate)

    for stableId in staleIds {
      guard let entry = active.removeValue(forKey: stableId) else { continue }
      recycle(entry)
    }

    for item in items {
      apply(item, animate: animate)
    }

    CATransaction.commit()
  }

  func clearAvatars() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    for entry in active.values {
      recycle(entry)
    }
    active.removeAll()

    CATransaction.commit()
  }

  private func apply(_ item: MessageAvatarOverlayItem, animate: Bool) {
    guard item.frame.width > 0, item.frame.height > 0 else {
      if let entry = active.removeValue(forKey: item.stableId) {
        recycle(entry)
      }
      return
    }

    let size = max(item.frame.width, item.frame.height)
    let key = ReuseKey(userInfo: item.userInfo, size: size)
    let entry: Entry

    if let current = active[item.stableId] {
      current.view.configure(with: item.userInfo, size: size)
      current.reuseKey = key
      entry = current
    } else {
      entry = dequeueEntry(for: item.userInfo, key: key, size: size)
      addSubview(entry.view)
      active[item.stableId] = entry
    }

    entry.tapTarget.onTap = item.onTap
    let frame = resolvedFrame(for: item)
    guard entry.frame != frame else { return }

    entry.frame = frame
    if animate {
      UIView.animate(withDuration: 0.18) {
        entry.view.frame = frame
      }
    } else {
      UIView.performWithoutAnimation {
        entry.view.frame = frame
      }
    }
  }

  private func resolvedFrame(for item: MessageAvatarOverlayItem) -> CGRect {
    var frame = pixelAligned(item.frame)
    let stickyY = item.viewportFrame.maxY - MessageAvatarOverlayConfig.viewportEdgeInset - frame.height
    frame.origin.y = clamped(stickyY, min: item.limitFrame.minY, max: frame.origin.y)
    return pixelAligned(frame)
  }

  private func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    guard minValue <= maxValue else { return maxValue }
    return Swift.min(Swift.max(value, minValue), maxValue)
  }

  private func pixelAligned(_ rect: CGRect) -> CGRect {
    let scale = window?.screen.scale ?? UIScreen.main.scale
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

  private func dequeueEntry(for userInfo: UserInfo, key: ReuseKey, size: CGFloat) -> Entry {
    if var entries = pool[key], let entry = entries.popLast() {
      pooledViewCount = max(0, pooledViewCount - 1)
      if entries.isEmpty {
        pool.removeValue(forKey: key)
      } else {
        pool[key] = entries
      }
      entry.view.configure(with: userInfo, size: size)
      entry.reuseKey = key
      return entry
    }

    let view = UserAvatarView()
    view.translatesAutoresizingMaskIntoConstraints = true
    view.configure(with: userInfo, size: size)
    return Entry(view: view, reuseKey: key)
  }

  private func recycle(_ entry: Entry) {
    entry.tapTarget.onTap = nil
    entry.frame = .null
    entry.view.removeFromSuperview()

    guard pooledViewCount < MessageAvatarOverlayConfig.maxPooledViews else { return }
    var entries = pool[entry.reuseKey, default: []]
    guard entries.count < MessageAvatarOverlayConfig.maxPooledViewsPerKey else { return }

    entries.append(entry)
    pool[entry.reuseKey] = entries
    pooledViewCount += 1
  }
}
