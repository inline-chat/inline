import SwiftUI

enum Layout {
  enum Chat {
    static let previewSize = CGSize(
      width: UIScreen.main.bounds.width * 0.95,
      height: UIScreen.main.bounds.height * 0.6
    )
  }

  enum Settings {
    enum ColorPicker {
      static let buttonSize: CGFloat = 36
      static let borderSize: CGFloat = 46
      static let spacing: CGFloat = 12
      static let minWidth: CGFloat = 40
    }
  }
}

// MARK: - Font Helpers

extension Font {
  static func customTitle(
    size: CGFloat = 17,
    weight: Weight = .medium,
    design: Design = .default
  ) -> Font {
    .system(size: size, weight: weight, design: design)
  }

  static func customCaption(
    size: CGFloat = 15,
    weight: Weight = .regular,
    design: Design = .default
  ) -> Font {
    .system(size: size, weight: weight, design: design)
  }

  static func smallLabel(
    size: CGFloat = 13,
    weight: Weight = .regular,
    design: Design = .default
  ) -> Font {
    .system(size: size, weight: weight, design: design)
  }
}
