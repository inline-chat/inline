import SwiftUI

class Theme {
  static var shared = Theme()

  init() {}

  // MARK: - Sizes

  let chatPreviewSize: CGSize = .init(width: UIScreen.main.bounds.width * 0.95, height: UIScreen.main.bounds.height * 0.6)
}
