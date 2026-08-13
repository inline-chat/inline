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
  private var representedHostedRow = SidebarHostedRow.empty
  private var panHandler: PanHandler?
  private var layoutHidesAccessibility = true
  private var suppressesHostedContentWhenHidden = true
  private var isHostedContentSuppressed = true

  private lazy var panRecognizer: NSPanGestureRecognizer = {
    let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    recognizer.buttonMask = 0x1
    return recognizer
  }()

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    // Every interactive row owns a full-width item and applies its visual
    // inset internally. Clipping is therefore a safe final boundary for the
    // collection's latent zero-height structural rows.
    root.clipsToBounds = true
    root.addGestureRecognizer(panRecognizer)
    view = root
  }

  func configure(
    row: SidebarCollectionRow,
    content: AnyView,
    isLayoutVisible: Bool,
    panHandler: @escaping PanHandler
  ) {
    let identityChanged = representedRowID != row.id
    representedRowID = row.id
    self.panHandler = panHandler
    panRecognizer.isEnabled = row.projectedItem?.orderLane != nil
    layoutHidesAccessibility = isLayoutVisible == false
    suppressesHostedContentWhenHidden = switch row.id {
    case .sectionHeader(.pinned), .pinDropGuide:
      true
    default:
      false
    }

    if identityChanged {
      resetLayerPresentation()
    }

    let hostedRow = SidebarHostedRow(rowID: row.id, content: content)
    representedHostedRow = hostedRow

    if let hostingView {
      // The collection item is the sole visual visibility owner. Keeping a
      // second `isHidden` bit on the reusable hosted child lets an old zero-
      // height/settling row hide the next semantic row assigned to this item.
      hostingView.isHidden = false
      synchronizeHostedAccessibility(refreshHostedContent: true)
      return
    }

    let hostingView = NSHostingView(rootView: SidebarHostedRow.empty)
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingView, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: view.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    self.hostingView = hostingView
    synchronizeHostedAccessibility(refreshHostedContent: true)
  }

  override func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
    super.apply(layoutAttributes)
    layoutHidesAccessibility = layoutAttributes.alpha <= 0.01
      || layoutAttributes.frame.height <= 0.5
    synchronizeHostedAccessibility()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedRowID = nil
    representedHostedRow = .empty
    panHandler = nil
    panRecognizer.isEnabled = false
    layoutHidesAccessibility = true
    suppressesHostedContentWhenHidden = true
    isHostedContentSuppressed = true
    hostingView?.rootView = .empty
    hostingView?.isHidden = true
    view.setAccessibilityHidden(true)
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

  private func synchronizeHostedAccessibility(refreshHostedContent: Bool = false) {
    let shouldSuppressHostedContent = suppressesHostedContentWhenHidden
      && layoutHidesAccessibility
    if refreshHostedContent || shouldSuppressHostedContent != isHostedContentSuppressed {
      hostingView?.rootView = shouldSuppressHostedContent ? .empty : representedHostedRow
      isHostedContentSuppressed = shouldSuppressHostedContent
    }

    // SwiftUI vends virtual descendants from the hosting boundary. Marking an
    // ancestor hidden alone does not consistently remove those descendants
    // from an NSCollectionView's flattened AX children, so also override the
    // hosted child lists while the structural row has no layout presence.
    hostingView?.setAccessibilityHidden(layoutHidesAccessibility)
    hostingView?.setAccessibilityChildren(layoutHidesAccessibility ? [] : nil)
    hostingView?.setAccessibilityChildrenInNavigationOrder(
      layoutHidesAccessibility ? [] : nil
    )
    view.setAccessibilityHidden(layoutHidesAccessibility)
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
