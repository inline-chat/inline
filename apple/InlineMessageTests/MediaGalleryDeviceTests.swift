import AVFoundation
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

  @Test("Decodes a large photo at screen size and swaps in the original for zooming")
  func largePhotoDecodesAtScreenSize() async throws {
    let (window, presenter, restore) = try Self.makeWindow()
    defer { restore() }
    let url = try Self.makePhoto(index: 3, size: CGSize(width: 4000, height: 3000))
    let item = MediaGalleryItem(
      id: 1, kind: .photo, mediaURL: url, fallbackURL: nil, thumbnailURL: nil,
      pixelSize: CGSize(width: 4000, height: 3000), strippedThumbnail: nil, duration: nil, message: nil
    )
    let viewer = MediaGalleryViewController(
      source: StaticMediaGallerySource(items: [item]), initialItemID: 1, sourceImage: nil,
      sourceViewProvider: { _ in nil }
    )
    presenter.present(viewer, animated: false)
    let cell = try await Self.waitForImage(in: viewer) { $0.size.width * $0.scale < 4000 }
    let scale = window.traitCollection.displayScale
    let shown = try #require(cell.imageView.image)
    // Fitted to a 390-point-wide page: about 390 x scale pixels wide, not 4000.
    #expect(shown.size.width * shown.scale <= (window.bounds.width * scale / 128).rounded(.up) * 128 + 1)

    cell.loadFullResolutionIfNeeded()
    _ = try await Self.waitForImage(in: viewer) { $0.size.width * $0.scale >= 4000 }
    viewer.dismissGallery()
    try await Self.waitForDismissal(viewer)
  }

  @Test("A long video skips, starts over when it has no message to remember, and hides the bars while playing")
  func longVideoSkipsResumesAndHidesChrome() async throws {
    let (window, presenter, restore) = try Self.makeWindow()
    defer { restore() }
    let videoURL = try await Self.makeVideo(seconds: 40)
    let video = MediaGalleryItem(
      id: 1, kind: .video, mediaURL: videoURL, fallbackURL: nil, thumbnailURL: nil,
      pixelSize: CGSize(width: 320, height: 240), strippedThumbnail: nil, duration: 40, message: nil
    )
    let photo = try MediaGalleryItem.photo(url: Self.makePhoto(index: 2), id: 2)
    let viewer = MediaGalleryViewController(
      source: StaticMediaGallerySource(items: [video, photo]), initialItemID: 1, sourceImage: nil,
      sourceViewProvider: { _ in nil }
    )
    presenter.present(viewer, animated: false)

    let player = try await Self.waitForPlayback(in: viewer)
    #expect(viewer.isChromeVisible)
    viewer.visiblePageCell?.showFeedback("15 s", systemImage: "goforward.15", leading: false)
    try await Task.sleep(for: .milliseconds(200))
    let shots = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-shots")
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    try Self.snapshot(window, to: shots.appendingPathComponent("video.png"))
    let before = player.currentTime().seconds
    viewer.perform(NSSelectorFromString("skipForwardFromKeyboard"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(player.currentTime().seconds > before + 4, "shift-right skips 5 s")

    // Four seconds of playback put the bars away.
    for _ in 0 ..< 60 where viewer.isChromeVisible {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!viewer.isChromeVisible, "bars hide during playback")

    let left = player.currentTime().seconds
    viewer.perform(NSSelectorFromString("showNextFromKeyboard"))
    try await Task.sleep(for: .milliseconds(700))
    #expect(viewer.visibleItemID == 2)
    #expect(viewer.currentVideoPlayer == nil, "leaving the page stops the video")
    viewer.perform(NSSelectorFromString("showPreviousFromKeyboard"))
    let resumed = try await Self.waitForPlayback(in: viewer)
    // This item has no message, so its position isn't kept: it starts over.
    #expect(resumed.currentTime().seconds < left)

    viewer.dismissGallery()
    try await Self.waitForDismissal(viewer)
  }

  // MARK: - Helpers

  private static func makeWindow() throws -> (UIWindow, UIViewController, () -> Void) {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    let presenter = UIViewController()
    window.rootViewController = presenter
    window.makeKeyAndVisible()
    return (window, presenter, {
      presenter.dismiss(animated: false)
      window.isHidden = true
      previousKeyWindow?.makeKey()
    })
  }

  private static func waitForImage(
    in viewer: MediaGalleryViewController,
    where predicate: (UIImage) -> Bool
  ) async throws -> MediaGalleryPageCell {
    for _ in 0 ..< 60 {
      if let cell = viewer.visiblePageCell, let image = cell.imageView.image, predicate(image) { return cell }
      try await Task.sleep(for: .milliseconds(100))
    }
    let size = viewer.visiblePageCell?.imageView.image.map { "\($0.size.width * $0.scale)" } ?? "none"
    Issue.record("The page never showed the expected image (width \(size)).")
    throw CancellationError()
  }

  private static func waitForPlayback(in viewer: MediaGalleryViewController) async throws -> AVPlayer {
    for _ in 0 ..< 80 {
      if let player = viewer.currentVideoPlayer, player.timeControlStatus == .playing { return player }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("The video never started playing.")
    throw CancellationError()
  }

  private static func waitForDismissal(_ viewer: MediaGalleryViewController) async throws {
    for _ in 0 ..< 30 where viewer.presentingViewController != nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(viewer.presentingViewController == nil)
  }

  /// A silent H.264 clip, two frames a second, each a different color.
  private static func makeVideo(seconds: Int) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-video-\(seconds).mp4")
    if FileManager.default.fileExists(atPath: url.path) { return url }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0 ... seconds * 2 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      let pool = try #require(adaptor.pixelBufferPool)
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      let pixels = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      let base = try #require(CVPixelBufferGetBaseAddress(pixels))
      memset(base, Int32(frame * 7 % 255), CVPixelBufferGetDataSize(pixels))
      CVPixelBufferUnlockBaseAddress(pixels, [])
      adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 2))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return url
  }

  private static func makePhoto(index: Int, size: CGSize? = nil) throws -> URL {
    let size = size ?? (index.isMultiple(of: 2) ? CGSize(width: 1200, height: 900) : CGSize(width: 900, height: 1200))
    let hue = CGFloat(index) / 8
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
      let text = "\(index)" as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size.height * 0.3, weight: .bold),
        .foregroundColor: UIColor.white,
      ]
      let textSize = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
        withAttributes: attributes
      )
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("gallery-photo-\(index)-\(Int(size.width))x\(Int(size.height)).jpg")
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
