import UIKit

/// One visible-list snapshot, captured before interrupting the previous animator.
@MainActor
struct MessageListGeometrySnapshotV2 {
  private struct Entry {
    let cell: UICollectionViewCell
    let targetTransform: CGAffineTransform
    let frameInWindow: CGRect
  }

  private let entries: [Entry]

  init(cells: [UICollectionViewCell], window: UIWindow) {
    entries = cells.map { cell in
      let frame: CGRect = if let presentation = cell.layer.presentation(), let parent = cell.superview {
        parent.convert(presentation.frame, to: window)
      } else {
        cell.convert(cell.bounds, to: window)
      }
      return Entry(cell: cell, targetTransform: cell.transform, frameInWindow: frame)
    }
  }

  func applyTargetTransforms() {
    for entry in entries {
      entry.cell.transform = entry.targetTransform
    }
  }

  func restorePresentedPositions(window: UIWindow) {
    for entry in entries {
      let cell = entry.cell
      let newFrame = cell.convert(cell.bounds, to: window)
      let deltaY = entry.frameInWindow.minY - newFrame.minY
      guard abs(deltaY) > 0.25, let parent = cell.superview else { continue }
      let origin = parent.convert(CGPoint.zero, to: window)
      let unitY = parent.convert(CGPoint(x: 0, y: 1), to: window)
      let scaleY = unitY.y - origin.y
      guard abs(scaleY) > 0.001 else { continue }
      cell.transform = CGAffineTransform(translationX: 0, y: deltaY / scaleY)
        .concatenating(entry.targetTransform)
    }
  }
}
