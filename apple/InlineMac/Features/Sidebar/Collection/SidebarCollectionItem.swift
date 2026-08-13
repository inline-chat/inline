import AppKit
import QuartzCore
import SwiftUI

private struct SidebarHostedRow: View {
  let rowID: SidebarCollectionRow.ID?
  let content: AnyView

  var body: some View {
    content.id(rowID)
  }

  static var empty: SidebarHostedRow {
    SidebarHostedRow(rowID: nil, content: AnyView(EmptyView()))
  }
}

/// Reusable collection item whose hosted SwiftUI identity is explicitly tied
/// to the semantic row ID. Reuse clears all content and presentation state.
final class SidebarCollectionBodyItem: NSCollectionViewItem {
  typealias PanHandler = (
    SidebarCollectionRow.ID,
    NSGestureRecognizer.State,
    CGPoint,
    CGPoint
  ) -> Void

  private var hostingView: NSHostingView<SidebarHostedRow>?
  private(set) var representedRowID: SidebarCollectionRow.ID?
  private var panHandler: PanHandler?

  private lazy var panRecognizer: NSPanGestureRecognizer = {
    let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    recognizer.buttonMask = 0x1
    return recognizer
  }()

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.addGestureRecognizer(panRecognizer)
    view = root
  }

  func configure(
    row: SidebarCollectionRow,
    content: AnyView,
    panHandler: @escaping PanHandler
  ) {
    let identityChanged = representedRowID != row.id
    representedRowID = row.id
    self.panHandler = panHandler
    panRecognizer.isEnabled = row.projectedItem?.orderLane != nil

    if identityChanged {
      resetLayerPresentation()
    }

    let hostedRow = SidebarHostedRow(rowID: row.id, content: content)

    if let hostingView {
      hostingView.isHidden = false
      hostingView.rootView = hostedRow
      return
    }

    let hostingView = NSHostingView(rootView: hostedRow)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingView, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: view.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    self.hostingView = hostingView
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedRowID = nil
    panHandler = nil
    panRecognizer.isEnabled = false
    hostingView?.rootView = .empty
    hostingView?.isHidden = true
    resetLayerPresentation()
  }

  @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
    guard let representedRowID,
          let collectionView = view.enclosingCollectionView
    else { return }
    panHandler?(
      representedRowID,
      recognizer.state,
      recognizer.location(in: collectionView),
      recognizer.translation(in: collectionView)
    )
  }

  private func resetLayerPresentation() {
    view.alphaValue = 1
    guard let layer = view.layer else { return }
    layer.removeAllAnimations()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    CATransaction.commit()
  }
}

/// Collection-level Finder/file drag boundary. Internal sidebar reordering is
/// intentionally handled by the controller's own pointer state machine.
final class SidebarExternalDropCollectionView: NSCollectionView {
  var draggingUpdatedHandler: ((NSDraggingInfo) -> NSDragOperation)?
  var draggingExitedHandler: ((NSDraggingInfo?) -> Void)?
  var performDragOperationHandler: ((NSDraggingInfo) -> Bool)?

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdatedHandler?(sender) ?? []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdatedHandler?(sender) ?? []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    draggingExitedHandler?(sender)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    draggingExitedHandler?(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    performDragOperationHandler?(sender) ?? false
  }
}

private extension NSView {
  var enclosingCollectionView: NSCollectionView? {
    if let collectionView = self as? NSCollectionView {
      return collectionView
    }
    return superview?.enclosingCollectionView
  }
}
