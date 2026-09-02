import AppKit
import Observation
import OSLog
import QuartzCore
import SwiftUI

#if DEBUG
/// Ephemeral, privacy-safe diagnostics for collection transition ownership.
/// Row tokens are process-seeded hashes: they correlate one Debug run without
/// persisting or disclosing chat identifiers, titles, or preview content.
enum SidebarCollectionTransitionDiagnostics {
  static let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac",
    category: "SidebarTransition"
  )

  static func rowToken(_ rowID: SidebarCollectionRow.ID?) -> UInt64 {
    guard let rowID else { return 0 }
    var hasher = Hasher()
    hasher.combine(rowID)
    return UInt64(bitPattern: Int64(hasher.finalize()))
  }

  static func itemToken(_ item: AnyObject) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(ObjectIdentifier(item))
    return UInt64(bitPattern: Int64(hasher.finalize()))
  }

  static func role(_ rowID: SidebarCollectionRow.ID?) -> NSString {
    let role = switch rowID {
    case .allChats: "all-chats"
    case .grid: "grid"
    case .archiveHeader: "archive-header"
    case .sectionHeader(.pinned): "pinned-header"
    case .sectionHeader(.content): "content-header"
    case .timelineHeader: "timeline-header"
    case .pinDropGuide: "pin-drop-guide"
    case .chat: "chat"
    case .folder: "folder"
    case .folderEmpty: "folder-empty"
    case .newThread: "new-thread"
    case .emptyState: "empty-state"
    case nil: "none"
    }
    return role as NSString
  }

  /// A/B controls for proving whether app-owned transition intervention is
  /// responsible for a defect that vanilla NSCollectionView does not exhibit.
  /// These exist only in Debug and are selected with explicit launch arguments.
  static let bypassesSemanticLayout = CommandLine.arguments.contains(
    "--sidebar-vanilla-layout"
  )
  static let bypassesItemLayerIntervention = CommandLine.arguments.contains(
    "--sidebar-vanilla-item-layers"
  )
  static let usesVanillaFlowLayout = CommandLine.arguments.contains(
    "--sidebar-vanilla-flow-layout"
  )
}
#endif

/// A transient projection owned by one reusable AppKit item. The semantic row
/// remains authoritative; this object only lets a surviving hosted view observe
/// disclosure changes without replacing its SwiftUI root or interaction state.
@MainActor
@Observable
final class SidebarCollectionRowHostState {
  private(set) var sectionIsExpanded: Bool?

  fileprivate func update(from row: SidebarCollectionRow) {
    sectionIsExpanded = row.sectionHeader?.isExpanded
  }

  fileprivate func reset() {
    sectionIsExpanded = nil
  }
}

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

/// The collection item's model frame can move to its destination before an
/// outgoing presentation layer has finished fading. The controller explicitly
/// disables only rows that leave the semantic snapshot; ordinary layout
/// attributes never latch pointer ownership.
private final class SidebarCollectionItemRootView: NSView {
  var allowsInteraction = false

  override func layout() {
    super.layout()
    for subview in subviews where subview.frame != bounds {
      subview.frame = bounds
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard allowsInteraction else { return nil }
    return super.hitTest(point)
  }
}

/// Reusable collection item whose hosted SwiftUI identity is explicitly tied
/// to the semantic row ID. Reuse clears semantic and presentation state while
/// preserving the native same-kind subtree needed by the hot scrolling path.
final class SidebarCollectionBodyItem: NSCollectionViewItem, NSGestureRecognizerDelegate {
  typealias PanHandler = (
    SidebarCollectionRow.ID,
    NSGestureRecognizer.State,
    CGPoint,
    CGPoint
  ) -> Void

  private var hostingView: NSHostingView<SidebarHostedRow>?
  private var nativeView: SidebarNativeRowView?
  private(set) var representedRowID: SidebarCollectionRow.ID?
  private var representedRow: SidebarCollectionRow?
  private var representedHostedRow = SidebarHostedRow.empty
  private let hostState = SidebarCollectionRowHostState()
  private var panHandler: PanHandler?
  private var layoutHidesAccessibility = true
  private var suppressesHostedContentWhenHidden = true
  private var isHostedContentSuppressed = true
  private var usesNativeContent = false
  private var interactionDisabledForSnapshotRemoval = false

  #if DEBUG
  private var transitionDebugConfigureGeneration = 0
  private var transitionDebugPreservesAnimations = false
  #endif

  var acceptsPointerInteraction: Bool {
    (viewIfLoaded as? SidebarCollectionItemRootView)?.allowsInteraction == true
  }

  /// SwiftUI fallback rows still need a conservative edge exclusion because
  /// their hosted controls do not expose native semantic hit regions.
  private static let controlStripWidth: CGFloat = 32
  private static let folderDisclosureStripWidth: CGFloat = 26

  private lazy var panRecognizer: NSPanGestureRecognizer = {
    let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    recognizer.buttonMask = 0x1
    recognizer.delaysPrimaryMouseButtonEvents = false
    recognizer.delegate = self
    return recognizer
  }()

  override func loadView() {
    let root = SidebarCollectionItemRootView()
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
    content: (SidebarCollectionRowHostState) -> AnyView,
    nativeConfiguration: SidebarNativeRowConfiguration?,
    isLayoutVisible: Bool,
    preservesCollectionTransition: Bool,
    panHandler: @escaping PanHandler
  ) {
    #if DEBUG
    let transitionDebugPreviousRowID = representedRowID
    transitionDebugConfigureGeneration += 1
    transitionDebugPreservesAnimations = preservesCollectionTransition
    defer {
      traceTransitionState(
        event: "configure-after",
        previousRowID: transitionDebugPreviousRowID
      )
    }
    traceTransitionState(
      event: "configure-before",
      previousRowID: transitionDebugPreviousRowID,
      prospectiveRowID: row.id
    )
    #endif

    let updatesSectionDisclosureInPlace = representedRow.map {
      isSectionDisclosureOnlyUpdate(from: $0, to: row)
    } ?? false
    let identityChanged = representedRowID != row.id
    representedRowID = row.id
    representedRow = row
    self.panHandler = panHandler
    interactionDisabledForSnapshotRemoval = false
    panRecognizer.isEnabled = row.projectedItem?.orderLane != nil
      || row.projectedFolder != nil
    layoutHidesAccessibility = isLayoutVisible == false
    (view as? SidebarCollectionItemRootView)?.allowsInteraction = isLayoutVisible
    suppressesHostedContentWhenHidden = switch row.id {
    case .sectionHeader(.pinned), .pinDropGuide:
      true
    default:
      false
    }

    // During an animated diff AppKit may reassign a reusable item while its
    // outgoing presentation is still part of the batch. Removing animations
    // here would snap the live item ahead of the collection-owned transition.
    if identityChanged && preservesCollectionTransition == false
      && shouldResetLayerPresentationForReuse {
      resetLayerPresentation()
    }

    hostState.update(from: row)

    if let nativeConfiguration {
      usesNativeContent = true
      representedHostedRow = .empty
      removeHostedRenderer()
      let nativeView = ensureNativeView()
      nativeView.isHidden = false
      nativeView.configure(nativeConfiguration)
      synchronizeHostedAccessibility()
      return
    }

    usesNativeContent = false
    removeNativeRenderer()
    let hostedRow = SidebarHostedRow(rowID: row.id, content: content(hostState))
    representedHostedRow = hostedRow

    if let hostingView {
      // The collection item is the sole visual visibility owner. Keeping a
      // second `isHidden` bit on the reusable hosted child lets an old zero-
      // height/settling row hide the next semantic row assigned to this item.
      hostingView.isHidden = false
      synchronizeHostedAccessibility(
        refreshHostedContent: updatesSectionDisclosureInPlace == false
      )
      return
    }

    let hostingView = NSHostingView(rootView: SidebarHostedRow.empty)
    hostingView.frame = view.bounds
    hostingView.autoresizingMask = [.width, .height]
    view.addSubview(hostingView, positioned: .below, relativeTo: nil)
    self.hostingView = hostingView
    synchronizeHostedAccessibility(refreshHostedContent: true)
  }

  override func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
    #if DEBUG
    traceTransitionState(event: "apply-before", layoutAttributes: layoutAttributes)
    #endif
    super.apply(layoutAttributes)
    layoutHidesAccessibility = layoutAttributes.alpha <= 0.01
      || layoutAttributes.frame.height <= 0.5
    (view as? SidebarCollectionItemRootView)?.allowsInteraction = !layoutHidesAccessibility
      && !interactionDisabledForSnapshotRemoval
    synchronizeHostedAccessibility()
    #if DEBUG
    traceTransitionState(event: "apply-after", layoutAttributes: layoutAttributes)
    #endif
  }

  /// Called before a diffable snapshot begins. A deleted item can remain in
  /// the hierarchy for its outgoing animation, but it must stop receiving
  /// mouse events and accessibility actions immediately. Survivors are never
  /// disabled merely because AppKit applies transitional alpha attributes.
  func disableInteractionForSnapshotRemoval() {
    interactionDisabledForSnapshotRemoval = true
    (view as? SidebarCollectionItemRootView)?.allowsInteraction = false
    nativeView?.setLayoutVisibility(false)
    view.setAccessibilityHidden(true)
    #if DEBUG
    traceTransitionState(event: "disable-for-removal")
    #endif
  }

  override func prepareForReuse() {
    #if DEBUG
    traceTransitionState(event: "prepare-for-reuse")
    #endif
    super.prepareForReuse()
    representedRowID = nil
    representedRow = nil
    representedHostedRow = .empty
    hostState.reset()
    usesNativeContent = false
    interactionDisabledForSnapshotRemoval = false
    panHandler = nil
    panRecognizer.isEnabled = false
    layoutHidesAccessibility = true
    suppressesHostedContentWhenHidden = true
    isHostedContentSuppressed = true
    hostingView?.rootView = .empty
    hostingView?.isHidden = true
    nativeView?.prepareForReuse()
    nativeView?.isHidden = true
    (view as? SidebarCollectionItemRootView)?.allowsInteraction = false
    view.setAccessibilityHidden(true)
    if shouldResetLayerPresentationForReuse {
      resetLayerPresentation()
    }
  }

  func setHovered(_ hovered: Bool) {
    nativeView?.setHovered(hovered)
  }

  /// Hit-test against the pixels AppKit is currently presenting, not a row's
  /// destination frame while collection or reorder motion is still settling.
  func hoverPresentationFrame(in collectionView: NSCollectionView) -> CGRect? {
    guard acceptsPointerInteraction,
          let superview = view.superview
    else { return nil }
    let frame = view.layer?.presentation()?.frame ?? view.frame
    return collectionView.convert(frame, from: superview)
  }

  func clearDisclosurePresentation() {
    #if DEBUG
    traceTransitionState(event: "clear-presentation-before")
    #endif
    resetLayerPresentation()
    #if DEBUG
    traceTransitionState(event: "clear-presentation-after")
    #endif
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

  func gestureRecognizer(
    _ gestureRecognizer: NSGestureRecognizer,
    shouldAttemptToRecognizeWith event: NSEvent
  ) -> Bool {
    guard gestureRecognizer === panRecognizer,
          event.type == .leftMouseDown
    else { return true }

    let point = view.convert(event.locationInWindow, from: nil)
    if usesNativeContent, let nativeView {
      let nativePoint = nativeView.convert(point, from: view)
      return nativeView.blocksReorder(at: nativePoint) == false
    }
    if representedRow?.projectedFolder != nil {
      return point.x >= Self.folderDisclosureStripWidth && view.bounds.contains(point)
    }
    let draggableBounds = view.bounds.insetBy(dx: Self.controlStripWidth, dy: 0)
    return draggableBounds.contains(point)
  }

  private func resetLayerPresentation() {
    view.alphaValue = 1
    guard let layer = view.layer else { return }
    layer.removeAllAnimations()
    layer.mask = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    CATransaction.commit()
  }

  private var shouldResetLayerPresentationForReuse: Bool {
    #if DEBUG
    return SidebarCollectionTransitionDiagnostics.bypassesItemLayerIntervention == false
    #else
    return true
    #endif
  }

  #if DEBUG
  func traceTransitionState(
    event: String,
    previousRowID: SidebarCollectionRow.ID? = nil,
    prospectiveRowID: SidebarCollectionRow.ID? = nil,
    layoutAttributes: NSCollectionViewLayoutAttributes? = nil
  ) {
    guard isViewLoaded else {
      os_log(
        .debug,
        log: SidebarCollectionTransitionDiagnostics.log,
        "component=item event=%{public}@ item=%{public}llu loaded=0 configure=%{public}d row-role=%{public}@ row=%{public}llu old-row=%{public}llu prospective-row=%{public}llu preserve=%{public}d",
        event as NSString,
        SidebarCollectionTransitionDiagnostics.itemToken(self),
        transitionDebugConfigureGeneration,
        SidebarCollectionTransitionDiagnostics.role(representedRowID),
        SidebarCollectionTransitionDiagnostics.rowToken(representedRowID),
        SidebarCollectionTransitionDiagnostics.rowToken(previousRowID),
        SidebarCollectionTransitionDiagnostics.rowToken(prospectiveRowID),
        transitionDebugPreservesAnimations ? 1 : 0
      )
      return
    }

    let layer = view.layer
    let presentationLayer = layer?.presentation()
    let modelFrame = layer?.frame ?? view.frame
    let presentationFrame = presentationLayer?.frame ?? modelFrame
    let index = view.enclosingCollectionView?.indexPath(for: self)?.item ?? -1
    let attributeFrame = layoutAttributes?.frame ?? .null
    let animationCount = (layer?.animationKeys()?.count ?? 0)
      + (layer?.mask?.animationKeys()?.count ?? 0)
    let itemToken = SidebarCollectionTransitionDiagnostics.itemToken(self)
    let rowRole = SidebarCollectionTransitionDiagnostics.role(representedRowID)
    let rowToken = SidebarCollectionTransitionDiagnostics.rowToken(representedRowID)
    let previousRowToken = SidebarCollectionTransitionDiagnostics.rowToken(previousRowID)
    let prospectiveRowToken = SidebarCollectionTransitionDiagnostics.rowToken(
      prospectiveRowID
    )
    let attributeIndex = layoutAttributes?.indexPath?.item ?? -1
    let attributeY = attributeFrame.isNull ? -1 : Int(attributeFrame.minY.rounded())
    let attributeHeight = attributeFrame.isNull ? -1 : Int(attributeFrame.height.rounded())
    let attributeAlpha = layoutAttributes.map { Int(($0.alpha * 1_000).rounded()) } ?? -1
    let modelY = Int(modelFrame.minY.rounded())
    let modelHeight = Int(modelFrame.height.rounded())
    let presentationY = Int(presentationFrame.minY.rounded())
    let presentationHeight = Int(presentationFrame.height.rounded())
    let modelTranslationY = Int((layer?.transform.m42 ?? 0).rounded())
    let presentationTranslationY = Int(
      (presentationLayer?.transform.m42 ?? layer?.transform.m42 ?? 0).rounded()
    )
    os_log(
      .debug,
      log: SidebarCollectionTransitionDiagnostics.log,
      "component=item-identity event=%{public}@ item=%{public}llu configure=%{public}d row-role=%{public}@ row=%{public}llu old-row=%{public}llu prospective-row=%{public}llu index=%{public}d attr-index=%{public}d preserve=%{public}d native=%{public}d",
      event as NSString,
      itemToken,
      transitionDebugConfigureGeneration,
      rowRole,
      rowToken,
      previousRowToken,
      prospectiveRowToken,
      index,
      attributeIndex,
      transitionDebugPreservesAnimations ? 1 : 0,
      usesNativeContent ? 1 : 0
    )
    os_log(
      .debug,
      log: SidebarCollectionTransitionDiagnostics.log,
      "component=item-geometry event=%{public}@ item=%{public}llu attr-y=%{public}d attr-h=%{public}d attr-alpha=%{public}d model-y=%{public}d model-h=%{public}d presentation-y=%{public}d presentation-h=%{public}d model-translation-y=%{public}d presentation-translation-y=%{public}d animations=%{public}d",
      event as NSString,
      itemToken,
      attributeY,
      attributeHeight,
      attributeAlpha,
      modelY,
      modelHeight,
      presentationY,
      presentationHeight,
      modelTranslationY,
      presentationTranslationY,
      animationCount
    )
  }
  #endif

  private func isSectionDisclosureOnlyUpdate(
    from previous: SidebarCollectionRow,
    to next: SidebarCollectionRow
  ) -> Bool {
    guard previous.id == next.id,
          previous.height == next.height,
          let previousHeader = previous.sectionHeader,
          let nextHeader = next.sectionHeader
    else { return false }
    return previousHeader.section == nextHeader.section
      && previousHeader.isExpanded != nextHeader.isExpanded
  }

  private func synchronizeHostedAccessibility(refreshHostedContent: Bool = false) {
    if usesNativeContent {
      nativeView?.setLayoutVisibility(layoutHidesAccessibility == false)
      nativeView?.setAccessibilityHidden(layoutHidesAccessibility)
      let nativeAccessibilityChildren = layoutHidesAccessibility
        ? []
        : nativeView?.subviews ?? []
      nativeView?.setAccessibilityChildren(nativeAccessibilityChildren)
      nativeView?.setAccessibilityChildrenInNavigationOrder(nativeAccessibilityChildren)
      hostingView?.setAccessibilityHidden(true)
      hostingView?.setAccessibilityChildren([])
      hostingView?.setAccessibilityChildrenInNavigationOrder([])
      view.setAccessibilityHidden(layoutHidesAccessibility)
      return
    }

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

  private func ensureNativeView() -> SidebarNativeRowView {
    if let nativeView { return nativeView }
    let nativeView = SidebarNativeRowView()
    nativeView.frame = view.bounds
    nativeView.autoresizingMask = [.width, .height]
    view.addSubview(nativeView, positioned: .below, relativeTo: nil)
    self.nativeView = nativeView
    return nativeView
  }

  /// Renderer changes are rare, user-driven experimental transitions. Remove
  /// the inactive hierarchy instead of keeping two hosting trees layered in a
  /// reusable item: a hidden NSHostingView can retain presentation content for
  /// the current display transaction and can otherwise leave stale hit-testing
  /// state until the window is reconstructed.
  private func removeHostedRenderer() {
    guard let hostingView else { return }
    hostingView.rootView = .empty
    hostingView.removeFromSuperview()
    self.hostingView = nil
    isHostedContentSuppressed = true
  }

  private func removeNativeRenderer() {
    guard let nativeView else { return }
    nativeView.prepareForReuse()
    nativeView.removeFromSuperview()
    self.nativeView = nil
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
