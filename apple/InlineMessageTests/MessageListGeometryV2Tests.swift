@testable import InlineIOS
import Testing
import UIKit

@Suite("iOS live-list geometry", .serialized)
@MainActor
struct MessageListGeometryV2Tests {
  @Test("Interrupted row motion preserves position and reaches its destination", arguments: [false, true])
  func interruptedRows(inverted: Bool) async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let parent = UIView(frame: controller.view.bounds)
    if inverted { parent.transform = CGAffineTransform(scaleX: 1, y: -1) }
    controller.view.addSubview(parent)
    let cell = UICollectionViewCell(frame: CGRect(x: 20, y: 100, width: 200, height: 40))
    parent.addSubview(cell)
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(30))

    let first = MessageListGeometrySnapshotV2(cells: [cell], window: window)
    cell.frame.origin.y += 100
    first.restorePresentedPositions(window: window)
    let firstAnimator = UIViewPropertyAnimator(duration: 0.4, curve: .linear) {
      first.applyTargetTransforms()
    }
    firstAnimator.startAnimation()
    try await Task.sleep(for: .milliseconds(100))

    let before = try parent.convert(#require(cell.layer.presentation()).frame, to: window)
    let second = MessageListGeometrySnapshotV2(cells: [cell], window: window)
    firstAnimator.stopAnimation(false)
    firstAnimator.finishAnimation(at: .current)
    second.applyTargetTransforms()
    cell.frame.origin.y += 80
    let destination = cell.convert(cell.bounds, to: window)
    second.restorePresentedPositions(window: window)
    #expect(abs(cell.convert(cell.bounds, to: window).minY - before.minY) <= 1)

    let secondAnimator = UIViewPropertyAnimator(duration: 0.2, curve: .linear) {
      second.applyTargetTransforms()
    }
    secondAnimator.startAnimation()
    try await Task.sleep(for: .milliseconds(300))
    #expect(cell.transform == .identity)
    #expect(abs(cell.convert(cell.bounds, to: window).minY - destination.minY) <= 1)
  }
}
