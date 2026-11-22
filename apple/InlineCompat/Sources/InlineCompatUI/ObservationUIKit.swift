#if canImport(UIKit)
import ObjectiveC
import UIKit

/// Holds observation tokens for an object's lifetime.
@MainActor
public final class CompatObservationBag {
  private var tokens: [CompatObservationToken] = []

  public init() {}

  public func add(_ token: CompatObservationToken) {
    tokens.append(token)
  }

  public func cancelAll() {
    tokens.forEach { $0.cancel() }
    tokens.removeAll()
  }
}

@MainActor
private enum ObservationBagKey {
  static var key: UInt8 = 0
}

@MainActor
public protocol CompatObservationHost: AnyObject {}

extension UIView: CompatObservationHost {}
extension UIViewController: CompatObservationHost {}

extension CompatObservationHost {
  /// Tokens owned by this view or view controller; released with it.
  public var observationBag: CompatObservationBag {
    if let bag = objc_getAssociatedObject(self, &ObservationBagKey.key) as? CompatObservationBag {
      return bag
    }
    let bag = CompatObservationBag()
    objc_setAssociatedObject(self, &ObservationBagKey.key, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return bag
  }

  /// Runs `render` now (before the first frame) and again whenever a tracked property it read
  /// changes. Lives as long as `self`, or until the returned token is cancelled.
  ///
  /// Capture `self` weakly in `render`; the bag is owned by `self`.
  @discardableResult
  public func observe(_ render: @escaping @MainActor () -> Void) -> CompatObservationToken {
    let token = CompatObservation.observe(render)
    observationBag.add(token)
    return token
  }
}
#endif
