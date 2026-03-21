import CoreGraphics
import Foundation
import InlineKit
import Testing

@testable import InlineUI

#if os(iOS)
import UIKit
private typealias TestPlatformView = UIView
#else
import AppKit
private typealias TestPlatformView = NSView
#endif

@MainActor
@Suite("Platform photo view")
struct PlatformPhotoViewTests {
  @Test("shows tiny thumbnail background when enabled for stripped photo bytes")
  func showsTinyThumbnailBackgroundForStrippedPhotos() {
    let view = PlatformPhotoView()
    view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    view.showsTinyThumbnailBackground = true

    let photo = Photo(photoId: 42, format: .jpeg)
    let photoInfo = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 42, type: "s", width: 40, height: 30, size: 6, bytes: Data([1, 30, 40, 1, 2, 3])),
      ]
    )

    view.setPhoto(photoInfo)
    layout(view)

    let backgroundView = findTinyThumbnailBackground(in: view)
    #expect(backgroundView != nil)
    #expect(backgroundView?.isHidden == false)
  }

  private func findTinyThumbnailBackground(in view: TestPlatformView) -> InlineTinyThumbnailBackgroundView? {
    if let backgroundView = view as? InlineTinyThumbnailBackgroundView {
      return backgroundView
    }

    for subview in view.subviews {
      if let backgroundView = findTinyThumbnailBackground(in: subview) {
        return backgroundView
      }
    }

    return nil
  }

  private func layout(_ view: PlatformPhotoView) {
    #if os(iOS)
    view.layoutIfNeeded()
    #else
    view.layoutSubtreeIfNeeded()
    #endif
  }
}
