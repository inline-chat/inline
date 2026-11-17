import Foundation
import Testing
import UIKit
@testable import InlineIOS

/// Hosts the media gallery on generated local photos. Screenshots land in the host app's
/// `tmp/gallery-shots/` for review.
@MainActor
@Suite("Media gallery", .serialized)
struct MediaGalleryDeviceTests {
  @Test("Keeps the item on screen across a window resize and renders its toast in both styles")
  func resizeKeepsItemAndToastRenders() async throws {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    else {
      Issue.record("No active UIKit scene.")
      return
    }
    let shots = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-shots")
    try? FileManager.default.removeItem(at: shots)
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    // Wide first, like landscape; the narrow resize below clamps the pager's old offset.
    window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
    let presenter = UIViewController()
    presenter.view.backgroundColor = .systemBackground
    window.rootViewController = presenter
    let sourceView = UIView(frame: CGRect(x: 40, y: 40, width: 120, height: 160))
    presenter.view.addSubview(sourceView)

    let items = try (1 ... 8).map { index in
      try MediaGalleryItem.photo(url: Self.makePhoto(index: index), id: Int64(index))
    }
    let viewer = MediaGalleryViewController(
      source: StaticMediaGallerySource(items: items),
      initialItemID: 7,
      sourceImage: nil,
      sourceViewProvider: { _ in sourceView }
    )
    defer {
      presenter.dismiss(animated: false)
      window.isHidden = true
      previousKeyWindow?.makeKey()
    }
    window.makeKeyAndVisible()
    presenter.present(viewer, animated: false)
    try await Task.sleep(for: .milliseconds(700))
    #expect(viewer.visibleItemID == 7)
    #expect(viewer.isFirstResponder)

    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.layoutIfNeeded()
    viewer.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    #expect(viewer.visibleItemID == 7, "the page jumped on resize to \(String(describing: viewer.visibleItemID))")

    viewer.showToast("Saved to Photos", systemImage: "checkmark", persistent: true)
    try await Task.sleep(for: .milliseconds(400))
    try Self.snapshot(window, to: shots.appendingPathComponent("light.png"))
    window.overrideUserInterfaceStyle = .dark
    try await Task.sleep(for: .milliseconds(300))
    try Self.snapshot(window, to: shots.appendingPathComponent("dark.png"))

    viewer.dismissGallery()
    for _ in 0 ..< 30 where viewer.presentingViewController != nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(viewer.presentingViewController == nil)
    #expect(viewer.presentingViewController == nil)
  }

  private static func makePhoto(index: Int) throws -> URL {
    let size = index.isMultiple(of: 2) ? CGSize(width: 1200, height: 900) : CGSize(width: 900, height: 1200)
    let hue = CGFloat(index) / 8
    let image = UIGraphicsImageRenderer(size: size).image { context in
      UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let text = "\(index)" as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 360, weight: .bold),
        .foregroundColor: UIColor.white,
      ]
      let textSize = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
        withAttributes: attributes
      )
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-photo-\(index).jpg")
    try #require(image.jpegData(compressionQuality: 0.8)).write(to: url)
    return url
  }

  private static func snapshot(_ window: UIWindow, to url: URL) throws {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try #require(image.pngData()).write(to: url)
  }
}
