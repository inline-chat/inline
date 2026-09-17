@testable import InlineIOS
import InlineTheme
import Testing
import UIKit

@Suite("iOS live-list geometry", .serialized)
@MainActor
struct MessageListGeometryV2Tests {
  @Test("Deferred row snapshots do not move a reused message cell")
  func reusedCellRejectsOldPosition() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    let cell = MessageCollectionViewCell(frame: CGRect(x: 0, y: 100, width: 350, height: 60))
    controller.view.addSubview(cell)
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    let theme = ThemeManager.shared.snapshot(variant: .light)
    cell.configure(
      with: message, firstInGroup: true, lastInGroup: true, spaceId: nil,
      collectionWidth: 350, theme: theme, messageViewImplementation: .v2
    )
    let snapshot = MessageListGeometrySnapshotV2(cells: [cell], window: window)
    cell.prepareForReuse()
    message.message.globalId = (message.message.globalId ?? 90_000) + 1
    message.message.messageId += 1
    cell.configure(
      with: message, firstInGroup: true, lastInGroup: true, spaceId: nil,
      collectionWidth: 350, theme: theme, messageViewImplementation: .v2
    )
    cell.transform = CGAffineTransform(translationX: 0, y: 17)
    let currentFrame = cell.frame
    snapshot.applyTargetTransforms()
    snapshot.restorePresentedPositions(window: window)
    #expect(cell.transform == CGAffineTransform(translationX: 0, y: 17))
    #expect(cell.frame == currentFrame)
  }

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
