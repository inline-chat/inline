import SwiftUI

class Theme {
  static var shared = Theme()

  init() {}

  let chatPreviewSize: CGSize = .init(
    width: UIScreen.main.bounds.width * 0.95,
    height: UIScreen.main.bounds.height * 0.6
  )

  enum Settings {
    static let picker = ColorPicker.self
    enum ColorPicker {
      static let buttonSize: CGFloat = 36
      static let borderSize: CGFloat = 46
      static let spacing: CGFloat = 12
      static let minWidth: CGFloat = 40
    }
  }
}
