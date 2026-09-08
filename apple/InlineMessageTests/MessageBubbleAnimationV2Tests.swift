@testable import InlineIOS
import Testing
import UIKit

@Suite("iOS message bubble animation", .serialized)
@MainActor
struct MessageBubbleAnimationV2Tests {
  @Test("Stretchable bubble fill matches the canonical shape", arguments: [
    MessageBubbleTailSide.none, .leading, .trailing,
  ])
  func canonicalFillShape(side: MessageBubbleTailSide) throws {
    for size in [CGSize(width: 120, height: 37), CGSize(width: 280, height: 200)] {
      let bubble = MessageBubbleView(frame: CGRect(origin: .zero, size: size))
      bubble.useAnimatedGeometry()
      bubble.configure(side: side)
      bubble.backgroundColor = .black
      bubble.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat()
      format.scale = 2
      let renderer = UIGraphicsImageRenderer(size: size, format: format)
      let actual = renderer.image { bubble.layer.render(in: $0.cgContext) }
      let reference = renderer.image { _ in
        UIColor.black.setFill()
        MessageBubbleGeometry.path(in: bubble.bounds, side: side).fill()
      }
      let actualBytes = try alphaBytes(actual)
      let expectedBytes = try alphaBytes(reference)
      #expect(actualBytes.count == expectedBytes.count)
      let error = zip(actualBytes, expectedBytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
      let averageError = Double(error) / Double(max(1, actualBytes.count))
      #expect(averageError < 1, "Mean alpha difference: \(averageError), side: \(side), size: \(size)")
    }
  }

  private func alphaBytes(_ image: UIImage) throws -> [UInt8] {
    let image = try #require(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
  }

  @Test("Visible fill and mask interpolate with the bubble", arguments: [
    MessageBubbleTailSide.none, .leading, .trailing,
  ])
  func visibleFillInterpolates(side: MessageBubbleTailSide) async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.isHidden = false
    defer { window.isHidden = true }

    let bubble = MessageBubbleView(frame: CGRect(x: 20, y: 100, width: 180, height: 50))
    bubble.useAnimatedGeometry()
    bubble.configure(side: side)
    bubble.backgroundColor = .systemBlue
    try #require(window.rootViewController).view.addSubview(bubble)
    bubble.layoutIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(30))

    let fill = try #require(bubble.subviews.first { $0.mask != nil })
    let mask = try #require(fill.mask)
    let animator = UIViewPropertyAnimator(duration: 0.4, curve: .linear) {
      bubble.frame.size = CGSize(width: 260, height: 170)
      bubble.layoutIfNeeded()
    }
    animator.startAnimation()
    defer { if animator.state == .active { animator.stopAnimation(true) } }
    try await Task.sleep(for: .milliseconds(100))

    let bubbleHeight = try #require(bubble.layer.presentation()).bounds.height
    let fillHeight = try #require(fill.layer.presentation()).bounds.height
    let maskHeight = try #require(mask.layer.presentation()).bounds.height
    #expect(bubbleHeight > 50 && bubbleHeight < 170)
    #expect(abs(fillHeight - bubbleHeight) <= 1)
    #expect(abs(maskHeight - bubbleHeight) <= 1)
  }
}
