#if os(iOS)
import Foundation
import SwiftUI
import UIKit

enum AttachmentPickerTileMetrics {
  static let thumbnailSide: CGFloat = 110
  static let rowVerticalInset: CGFloat = 2
  static let rowHeight: CGFloat = thumbnailSide + (rowVerticalInset * 2)
  static let cornerRadius: CGFloat = 18
  static let tileSpacing: CGFloat = 12
  static let selectionIndicatorSize: CGFloat = 22
  static let verticalPreviewScrimHeight: CGFloat = 46
  static let videoBadgeHeight: CGFloat = 22
  static let videoBadgeHorizontalInset: CGFloat = 10
  static let videoBadgeBottomInset: CGFloat = 6
  static let videoBadgeSpacing: CGFloat = 6
  static let contentBottomPadding: CGFloat = 24
  static let floatingButtonHorizontalPadding: CGFloat = 28
  static let floatingButtonBottomInset: CGFloat = 12
  static let defaultInitialRecentLimit = 25
  static let defaultRecentLimit = defaultInitialRecentLimit * 3

  static var thumbnailPixelSize: CGSize {
    let scale = UIScreen.main.scale
    return CGSize(
      width: thumbnailSide * scale,
      height: thumbnailSide * scale
    )
  }
}

enum AttachmentPickerVideoDurationFormatter {
  static func string(for duration: TimeInterval?) -> String? {
    guard let duration, duration.isFinite, duration > 0 else { return nil }

    let totalSeconds = Int(duration.rounded(.down))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    return String(format: "%d:%02d", minutes, seconds)
  }
}
#endif
