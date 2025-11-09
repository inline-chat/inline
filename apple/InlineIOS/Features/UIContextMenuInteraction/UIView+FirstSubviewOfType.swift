import UIKit

extension UIView {
  func firstSubview<T: UIView>(ofType type: T.Type) -> T? {
    for subview in subviews {
      if let candidate = subview as? T {
        return candidate
      } else if let candidate = subview.firstSubview(ofType: type) {
        return candidate
      }
    }

    return nil
  }
}
