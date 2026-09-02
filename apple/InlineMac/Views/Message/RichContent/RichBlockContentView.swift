import AppKit
import InlineKit
import InlineProtocol
import Quartz
import TextProcessing

final class RichBlockContentView: NSView, NSUserInterfaceValidations {
  var onDisclosureToggle: ((BlockContentPath, Bool) -> Void)?
  var onTextEntityClick: ((MessageTextEntityHit, NSAttributedString) -> Bool)?
  var onTextLongPress: ((NSEvent) -> Void)?

  private var nodeViews: [BlockContentPath: RichBlockRenderableView] = [:]
  private var previousSource: String?
  private var previousContent: InlineProtocol.BlockContent?
  private var currentPlan: RichBlockLayoutPlan?
  private var mathSnapshot: RichTextMath.Snapshot?
  private var mathLayoutSignature: Int = 0
  private var mathPreparationTask: Task<Void, Never>?
  private var mathGeneration: UInt64 = 0
  private var mathPrepared = false
  private var mathMessageStableID: Int64 = 0
  private var messageIdentity: BlockContentMessageIdentity?
  private var isContentVisible = true
  private var previewGallery: BlockImageGallery?
  private var previewItems: [RichBlockPreviewItem] = []
  private var previewURLs: [Int64: URL] = [:]
  private var previewLoadTask: Task<Void, Never>?
  private var previewGeneration: UInt64 = 0
  private var previewWasPresented = false
  private weak var loadingPreviewView: RichBlockImageNodeView?
  private lazy var multiSurfaceSelection = RichBlockMultiSurfaceSelectionCoordinator(owner: self)

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    clipsToBounds = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    plan: RichBlockLayoutPlan,
    content: InlineProtocol.BlockContent,
    attributedText: NSAttributedString,
    baseFontSize: CGFloat,
    palette: RichBlockPalette,
    relatedMessage: InlineKit.Message,
    codePresentation: RichBlockCodePresentation = .syntaxHighlighted,
    renderStyle: MessageRenderStyle,
    animated: Bool
  ) {
    // An async render may fill or evict the shared cache between measurement
    // and binding. Use the exact measured projection until the normal layout
    // update commits a newer snapshot; never change inline wrapping here.
    guard let math = plan.mathSnapshot, math.signature == plan.mathSignature else {
      assertionFailure("Rich block geometry must be prepared before binding")
      return
    }
    let accessibilityStructureChanged = selectionTopology(for: currentPlan) != selectionTopology(for: plan)
    let identity = BlockContentMessageIdentity(message: relatedMessage)
    let identityChanged = messageIdentity != identity
    if identityChanged {
      prepareForReuse()
      messageIdentity = identity
    }
    let sourceChanged: Bool = switch (previousSource, relatedMessage.text) {
    case (nil, nil): false
    case let (previous?, current?): !previous.utf8.elementsEqual(current.utf8)
    default: true
    }
    let contentChanged = previousContent.map { $0 != content } ?? false
    if sourceChanged || contentChanged
      || selectionTopology(for: currentPlan) != selectionTopology(for: plan)
    {
      multiSurfaceSelection.clear()
    }
    if previewGallery != nil, sourceChanged || previousContent.map({ $0 != content }) == true {
      // Quick Look owns an immutable tap-time gallery. A streamed structural
      // revision must close only this view's panel before its source nodes move.
      clearPreview()
    }
    let reconciliation = BlockContentReconciler.reconcile(
      previous: previousContent, current: content,
      previousSource: previousSource, currentSource: relatedMessage.text ?? ""
    )
    previousSource = relatedMessage.text
    previousContent = content
    currentPlan = plan
    let context = RichBlockRenderContext(
      math: math,
      attributedText: attributedText,
      baseFontSize: baseFontSize,
      palette: palette,
      relatedMessage: relatedMessage,
      interactions: .init(
        onTextEntityClick: { [weak self] hit, text in
          self?.onTextEntityClick?(hit, text) ?? false
        },
        onDisclosureToggle: { [weak self] path, expanded in
          self?.onDisclosureToggle?(path, expanded)
        },
        onImageClick: { [weak self] image in
          self?.openImage(image)
        }
      ),
      isContentVisible: isContentVisible,
      codePresentation: codePresentation,
      renderStyle: renderStyle,
      contentHorizontalInset: plan.contentHorizontalInset
    )

    // Detach the dictionary before applying moves: a swap must not overwrite
    // the view we still need for a later destination.
    var remainingViews = nodeViews
    nodeViews.removeAll(keepingCapacity: true)
    for node in plan.nodes {
      guard let oldPath = reconciliation.previousPathByCurrentPath[node.path],
            let view = remainingViews[oldPath], view.reuseKind == node.reuseKind
      else { continue }
      nodeViews[node.path] = remainingViews.removeValue(forKey: oldPath)
    }
    for removed in remainingViews.values {
      removed.prepareForReuse()
      removed.removeFromSuperview()
    }

    let shouldAnimate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var frameChanges: [(RichBlockRenderableView, CGRect)] = []
    for node in plan.nodes {
      let view: RichBlockRenderableView
      if let reusable = nodeViews[node.path],
         reusable.reuseKind == node.reuseKind
      {
        view = reusable
      } else {
        view = RichBlockViewFactory.make(for: node)
        nodeViews[node.path] = view
        addSubview(view)
      }
      // New renderers need their measured bounds before apply; image views use
      // those bounds to choose an initial decode target.
      if view.frame == .zero {
        view.frame = node.frame
      }
      view.apply(node: node, context: context)
      // Rich child text views perform their own native tracking. Connect their
      // existing hold timer independently of the optional selection experiment.
      let supportsTextHold: Bool = switch node.reuseKind {
      case .disclosure, .code: false
      default: onTextLongPress != nil
      }
      for surface in view.orderedTextSurfaces {
        surface.configureTextLongPress(supportsTextHold ? { [weak self] event in
          self?.onTextLongPress?(event)
        } : nil)
      }
      view.setContentVisible(isContentVisible)
      if shouldAnimate, view.frame != .zero, view.frame != node.frame {
        frameChanges.append((view, node.frame))
      } else {
        view.frame = node.frame
      }
    }

    animate(frameChanges)
    configureMultiSurfaceSelection(for: plan)
    mathMessageStableID = relatedMessage.stableId
    updateMathPreparation(math, layoutSignature: plan.mathSignature)
    if identityChanged || sourceChanged || contentChanged || accessibilityStructureChanged {
      NSAccessibility.post(
        element: self,
        notification: .layoutChanged,
        userInfo: [.uiElements: [self]]
      )
    }
  }

  func applyLayout(_ plan: RichBlockLayoutPlan, animated: Bool) {
    if selectionTopology(for: currentPlan) != selectionTopology(for: plan) {
      multiSurfaceSelection.clear()
    }
    currentPlan = plan
    let shouldAnimate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let frameChanges = plan.nodes.compactMap { node -> (RichBlockRenderableView, CGRect)? in
      guard let view = nodeViews[node.path], view.reuseKind == node.reuseKind else { return nil }
      view.updateLayout(node: node)
      if shouldAnimate, view.frame != .zero, view.frame != node.frame {
        return (view, node.frame)
      }
      view.frame = node.frame
      return nil
    }
    animate(frameChanges)
    configureMultiSurfaceSelection(for: plan)
  }

  func setContentVisible(_ visible: Bool) {
    guard isContentVisible != visible else { return }
    isContentVisible = visible
    if visible { startMathPreparation() } else { cancelMathPreparation() }
    for view in nodeViews.values {
      view.setContentVisible(visible)
    }
  }

  func consumeNestedHorizontalScroll(_ event: NSEvent) -> Bool {
    guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point),
          var candidate = hitTest(convert(point, to: superview)) else { return false }
    while candidate !== self {
      // Native nested scroll views already applied AppKit's natural direction,
      // momentum, and edge behavior. If the event continues up the responder
      // chain, consume it here so message swipe-to-reply cannot also claim it.
      if candidate is NSScrollView {
        return true
      }
      if let surface = candidate as? RichBlockHorizontalScrollSurface {
        return surface.consumeHorizontalScroll(event)
      }
      guard let parent = candidate.superview else { return false }
      candidate = parent
    }
    return false
  }

  override func prepareForReuse() {
    multiSurfaceSelection.configure(surfaces: [], document: [], literals: [], enabled: false)
    cancelMathPreparation()
    mathSnapshot = nil
    mathMessageStableID = 0
    clearPreview()
    super.prepareForReuse()
    for view in nodeViews.values {
      view.prepareForReuse()
      view.removeFromSuperview()
    }
    nodeViews.removeAll(keepingCapacity: true)
    previousContent = nil
    previousSource = nil
    currentPlan = nil
    messageIdentity = nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didResignKeyNotification,
      object: nil
    )
    NotificationCenter.default.removeObserver(
      self,
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
    if window == nil {
      multiSurfaceSelection.clear()
      clearPreview()
      cancelMathPreparation()
    } else {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(selectionContextDidDeactivate),
        name: NSWindow.didResignKeyNotification,
        object: window
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(selectionContextDidDeactivate),
        name: NSApplication.didResignActiveNotification,
        object: nil
      )
      startMathPreparation()
    }
  }

  override func resignFirstResponder() -> Bool {
    if !multiSurfaceSelection.isTrackingGesture {
      multiSurfaceSelection.clear()
    }
    return super.resignFirstResponder()
  }

  @objc private func selectionContextDidDeactivate() {
    multiSurfaceSelection.clear()
  }

  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(NSText.copy(_:)) { return multiSurfaceSelection.hasSelection }
    if item.action == #selector(NSText.selectAll(_:)) { return multiSurfaceSelection.canSelectAll }
    return true
  }

  @objc func copy(_ sender: Any?) {
    _ = multiSurfaceSelection.writeSelection(to: .general)
  }

  override func selectAll(_ sender: Any?) {
    multiSurfaceSelection.selectAll()
  }

  var hasMultiSurfaceSelection: Bool { multiSurfaceSelection.hasSelection }

  func retargetMultiSurfaceCopy(in menu: NSMenu) -> NSMenu {
    guard multiSurfaceSelection.hasSelection else { return menu }
    let copyAction = #selector(NSText.copy(_:))
    let item = menu.items.first(where: { $0.action == copyAction }) ?? {
      let item = NSMenuItem(title: "Copy Selected Text", action: copyAction, keyEquivalent: "c")
      menu.insertItem(item, at: 0)
      return item
    }()
    item.title = "Copy Selected Text"
    item.action = copyAction
    item.target = self
    item.isEnabled = true
    item.keyEquivalent = "c"
    for other in menu.items where other !== item && other.keyEquivalent == "c" {
      other.keyEquivalent = ""
    }
    return menu
  }

  private func updateMathPreparation(_ snapshot: RichTextMath.Snapshot?, layoutSignature: Int) {
    if mathSnapshot?.requests != snapshot?.requests || mathSnapshot?.signature != snapshot?.signature
      || mathLayoutSignature != layoutSignature {
      cancelMathPreparation()
    }
    mathSnapshot = snapshot
    mathLayoutSignature = layoutSignature
    startMathPreparation()
  }

  private func cancelMathPreparation() {
    mathGeneration &+= 1
    mathPreparationTask?.cancel()
    mathPreparationTask = nil
    mathPrepared = false
  }

  private func startMathPreparation() {
    guard window != nil, isContentVisible, !mathPrepared, mathPreparationTask == nil,
          let snapshot = mathSnapshot?.refreshed(), !snapshot.requests.isEmpty else { return }
    guard snapshot.hasPending || snapshot.signature != mathLayoutSignature
      || snapshot.signature != mathSnapshot?.signature else {
      mathPrepared = true
      return
    }
    let generation = mathGeneration
    mathPreparationTask = Task { @MainActor [weak self] in
      _ = await RichTextMath.prepare(snapshot.requests)
      guard !Task.isCancelled, let self, self.window != nil,
            self.mathGeneration == generation else { return }
      self.mathPreparationTask = nil
      self.mathPrepared = true
      // Cached success alone is not a change. In particular, rebinding a ready
      // row must never trigger a notification/reload/rebind loop.
      let ready = snapshot.refreshed()
      guard ready.signature != self.mathLayoutSignature || ready.signature != self.mathSnapshot?.signature else { return }
      NotificationCenter.default.post(
        name: .richBlockLayoutStateDidChange, object: self,
        userInfo: ["messageStableID": self.mathMessageStableID]
      )
    }
  }

  /// Native selection/copy controls must consume message-level double clicks.
  /// Hit testing the outer (empty) MessageTextView cannot see rich descendants.
  func interactiveTextHitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point) else { return nil }
    func find(in view: NSView) -> NSView? {
      let local = view.convert(point, from: self)
      // visibleRect can extend outside a non-clipping view's bounds. Without
      // this check, an earlier paragraph steals clicks from following blocks.
      guard !view.isHidden, view.bounds.contains(local), view.visibleRect.contains(local) else { return nil }
      if let disclosure = view as? RichBlockDisclosureNodeView {
        return disclosure.interactiveHitTest(local)
      }
      if let text = view as? NSTextView, text.isSelectable { return text }
      if view is NSControl || view is RichBlockMathNodeView { return view }
      for child in view.subviews.reversed() {
        if let hit = find(in: child) { return hit }
      }
      return nil
    }
    for node in currentPlan?.nodes ?? [] {
      if let view = nodeViews[node.path], let hit = find(in: view) { return hit }
    }
    return nil
  }

  private struct SelectionTopologyItem: Equatable {
    let path: BlockContentPath
    let kind: RichBlockRenderKind
    let surfaceCount: Int
  }

  private struct SelectionProjection {
    var surfaces: [RichBlockTextSurface]
    var document: [RichTextMultiSurfaceSelection.DocumentItem]
    var literals: [NSAttributedString]
  }

  private func selectionTopology(for plan: RichBlockLayoutPlan?) -> [SelectionTopologyItem] {
    plan?.nodes.compactMap { node in
      let surfaceCount: Int
      switch node.kind {
      case let .text(text):
        if case .listMarker = text.role { return nil }
        surfaceCount = 1
      case .code:
        surfaceCount = 1
      case let .math(math):
        surfaceCount = math.imageSize == nil ? 1 : 0
      case let .table(table):
        surfaceCount = table.cells.count
      default:
        return nil
      }
      return SelectionTopologyItem(path: node.path, kind: node.reuseKind, surfaceCount: surfaceCount)
    } ?? []
  }

  private func configureMultiSurfaceSelection(for plan: RichBlockLayoutPlan) {
    guard AppSettings.shared.richTextMultiSurfaceSelectionEnabled,
          let projection = selectionProjection(for: plan)
    else {
      multiSurfaceSelection.configure(surfaces: [], document: [], literals: [], enabled: false)
      return
    }
    multiSurfaceSelection.configure(
      surfaces: projection.surfaces,
      document: projection.document,
      literals: projection.literals,
      enabled: true
    )
  }

  private func selectionProjection(for plan: RichBlockLayoutPlan) -> SelectionProjection? {
    let surfacesByNode = plan.nodes.map { nodeViews[$0.path]?.orderedTextSurfaces ?? [] }
    let surfaces = surfacesByNode.flatMap { $0 }
    var surfaceIndices: [ObjectIdentifier: Int] = [:]
    for (index, surface) in surfaces.enumerated() {
      guard surfaceIndices.updateValue(index, forKey: ObjectIdentifier(surface)) == nil else { return nil }
    }
    var document: [RichTextMultiSurfaceSelection.DocumentItem] = []
    var literals: [NSAttributedString] = []

    func appendLiteral(
      _ source: NSAttributedString,
      leadingForSurface: Int? = nil,
      separatorAfter: String
    ) {
      guard source.length > 0 else { return }
      let index = literals.count
      literals.append(source)
      document.append(.init(
        content: .literal(index, leadingForSurface: leadingForSurface),
        separatorAfter: separatorAfter
      ))
    }

    func appendSurface(_ surface: RichBlockTextSurface, separatorAfter: String) -> Bool {
      guard let index = surfaceIndices[ObjectIdentifier(surface)] else { return false }
      document.append(.init(content: .surface(index), separatorAfter: separatorAfter))
      return true
    }

    for (nodeIndex, node) in plan.nodes.enumerated() {
      let nodeSurfaces = surfacesByNode[nodeIndex]
      switch node.kind {
      case let .text(text):
        if case .listMarker = text.role {
          guard let marker = nodeViews[node.path] as? RichBlockListMarkerNodeView else { continue }
          for candidateIndex in plan.nodes.indices.dropFirst(nodeIndex + 1) {
            let candidate = plan.nodes[candidateIndex]
            guard candidate.path.isStrictDescendant(of: node.path) else { break }
            if let surface = surfacesByNode[candidateIndex].first,
               let target = surfaceIndices[ObjectIdentifier(surface)] {
              appendLiteral(marker.selectionSource, leadingForSurface: target, separatorAfter: " ")
              break
            }
            if case .math = candidate.kind,
               let math = nodeViews[candidate.path] as? RichBlockMathNodeView,
               math.selectionSource.length > 0 {
              appendLiteral(marker.selectionSource, separatorAfter: " ")
              break
            }
          }
        } else {
          for surface in nodeSurfaces {
            guard appendSurface(surface, separatorAfter: "\n") else { return nil }
          }
        }
      case .code:
        for surface in nodeSurfaces {
          guard appendSurface(surface, separatorAfter: "\n") else { return nil }
        }
      case .math:
        if let surface = nodeSurfaces.first {
          guard nodeSurfaces.count == 1, appendSurface(surface, separatorAfter: "\n") else { return nil }
        } else if let math = nodeViews[node.path] as? RichBlockMathNodeView {
          appendLiteral(math.selectionSource, separatorAfter: "\n")
        }
      case let .table(table):
        guard nodeSurfaces.count == table.cells.count else { return nil }
        for index in table.cells.indices {
          let sameRow = index + 1 < table.cells.count
            && table.cells[index].frame.minY == table.cells[index + 1].frame.minY
          guard appendSurface(nodeSurfaces[index], separatorAfter: sameRow ? "\t" : "\n") else { return nil }
        }
      case .separator, .image, .album, .quote:
        guard nodeSurfaces.isEmpty else { return nil }
      }
    }
    guard surfaces.isEmpty || !document.isEmpty else { return nil }
    return SelectionProjection(surfaces: surfaces, document: document, literals: literals)
  }

  private var readyImageOccurrences: [BlockImageOccurrence] {
    (currentPlan?.nodes ?? []).flatMap { node -> [BlockImageOccurrence] in
      let images: [RichBlockLayoutPlan.ImageNode]
      switch node.kind {
      case let .image(image): images = [image]
      case let .album(album): images = album.items
      default: return []
      }
      return images.compactMap { image in
        guard case let .ready(photo) = image.state, photo.hasDisplayablePreview else { return nil }
        return BlockImageOccurrence(path: image.path, photo: photo)
      }
    }
  }

  private func imageView(at path: BlockContentPath, photoID: Int64) -> RichBlockImageNodeView? {
    if let image = nodeViews[path] as? RichBlockImageNodeView, image.matches(photoID: photoID) { return image }
    guard case .albumImage? = path.components.last else { return nil }
    let parent = BlockContentPath(Array(path.components.dropLast()))
    return (nodeViews[parent] as? RichBlockAlbumNodeView)?.imageView(at: path, photoID: photoID)
  }

  /// Receives a point in this view's coordinates. Clipping matters for scrolled
  /// albums; an offscreen occurrence must not claim a message gesture.
  func interactiveImageHitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(point) else { return nil }
    // Hit testing does not construct a gallery or touch photo/cache metadata.
    for node in currentPlan?.nodes ?? [] {
      guard let view = nodeViews[node.path] else { continue }
      if let image = view as? RichBlockImageNodeView, !image.isHidden,
         image.canOpenPreview,
         image.bounds.contains(image.convert(point, from: self)),
         image.visibleRect.contains(image.convert(point, from: self))
      {
        return image
      }
      if let album = view as? RichBlockAlbumNodeView,
         let hit = album.interactiveImageHitTest(album.convert(point, from: self))
      {
        return hit
      }
    }
    return nil
  }

  private func openImage(_ image: BlockImageOccurrence) {
    guard window != nil, let gallery = BlockImageGallery(
      images: readyImageOccurrences, selectedPath: image.path, selectedPhotoID: image.photo.id,
      resolveURL: { photo in
        if let cached = FileCache.cachedLocalURL(photo: photo) { return cached }
        guard let size = photo.bestPhotoSize(), size.type != "s", let cdnURL = size.cdnUrl else { return nil }
        return URL(string: cdnURL)
      }
    ) else { return }
    multiSurfaceSelection.clear()
    clearPreview()
    previewGallery = gallery
    let generation = previewGeneration
    let selected = gallery.items[gallery.initialIndex]
    for item in gallery.items {
      if let url = FileCache.cachedLocalURL(photo: item.image.photo) { previewURLs[item.occurrenceID] = url }
    }
    if previewURLs[selected.occurrenceID] != nil {
      guard publishPreviewItems(generation: generation) else { return }
    } else {
      loadingPreviewView = imageView(at: image.path, photoID: image.photo.id)
      loadingPreviewView?.setPreviewLoading(true)
    }

    // Existing FileCache owns downloads and deduplicates requests. This task only
    // materializes the tap snapshot, selected first; it never holds a cell across await.
    let order = [selected] + gallery.items.filter { $0.occurrenceID != selected.occurrenceID }
    previewLoadTask = Task { [weak self] in
      for item in order {
        guard !Task.isCancelled, self?.previewGeneration == generation else { return }
        if self?.previewURLs[item.occurrenceID] != nil { continue }
        let photo = item.image.photo
        let url = await FileCache.shared.downloadAndWait(photo: photo)
        guard !Task.isCancelled, self?.previewGeneration == generation else { return }
        guard let url else {
          if item.occurrenceID == selected.occurrenceID {
            self?.previewFailed(generation: generation)
            return
          }
          continue
        }
        self?.previewURLs[item.occurrenceID] = url
        guard self?.publishPreviewItems(generation: generation) == true else { return }
      }
      if self?.previewGeneration == generation { self?.previewLoadTask = nil }
    }
  }

  @discardableResult
  private func publishPreviewItems(generation: UInt64) -> Bool {
    guard previewGeneration == generation, let gallery = previewGallery, let window else { return false }
    guard let panel = QLPreviewPanel.shared() else { clearPreview(); return false }
    let selectedID: Int64
    if previewWasPresented {
      guard controlsPreviewPanel(panel), panel.isVisible,
            let current = panel.currentPreviewItem as? RichBlockPreviewItem
      else { clearPreview(); return false }
      selectedID = current.occurrenceID
    } else {
      selectedID = gallery.items[gallery.initialIndex].occurrenceID
      // A delayed click cannot steal focus or open a recycled/removed occurrence.
      guard window.isKeyWindow,
            gallery.sourcePath(for: selectedID, in: readyImageOccurrences) != nil
      else { clearPreview(); return false }
    }
    guard let projection = gallery.localProjection(urlsByOccurrence: previewURLs, selectedOccurrenceID: selectedID)
    else { return false }
    previewItems = projection.items.map { RichBlockPreviewItem(occurrenceID: $0.occurrenceID, url: $0.url) }
    if !previewWasPresented {
      guard window.makeFirstResponder(self) else { clearPreview(); return false }
      panel.updateController()
      guard controlsPreviewPanel(panel) else { clearPreview(); return false }
    }
    panel.reloadData()
    panel.currentPreviewItemIndex = projection.selectedIndex
    if !previewWasPresented {
      previewWasPresented = true
      panel.makeKeyAndOrderFront(nil)
    }
    loadingPreviewView?.setPreviewLoading(false)
    loadingPreviewView = nil
    return true
  }

  private func previewFailed(generation: UInt64) {
    guard previewGeneration == generation else { return }
    let showError = window?.isKeyWindow == true
    clearPreview()
    if showError { ToastCenter.shared.showError("Unable to open image. Please try again.") }
  }

  private func controlsPreviewPanel(_ panel: QLPreviewPanel) -> Bool {
    (panel.dataSource as AnyObject?) === self
  }

  private func clearPreview() {
    previewGeneration &+= 1
    previewLoadTask?.cancel()
    previewLoadTask = nil
    loadingPreviewView?.setPreviewLoading(false)
    loadingPreviewView = nil
    previewGallery = nil
    previewItems = []
    previewURLs = [:]
    previewWasPresented = false
    if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), controlsPreviewPanel(panel) {
      // Clear the delegate before orderOut to avoid reentrant teardown callbacks.
      panel.dataSource = nil
      panel.delegate = nil
      panel.orderOut(nil)
      // Relinquish the responder controller too, so a later click can begin
      // control again even when this view remains first responder.
      panel.updateController()
    }
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    window != nil && !previewItems.isEmpty
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    if controlsPreviewPanel(panel) {
      panel.dataSource = nil
      panel.delegate = nil
    }
    clearPreview()
  }

  private func previewSource(for item: QLPreviewItem?) -> RichBlockImageNodeView? {
    guard let item = item as? RichBlockPreviewItem, let gallery = previewGallery,
          let image = gallery.items.first(where: { $0.occurrenceID == item.occurrenceID })?.image,
          let path = gallery.sourcePath(for: item.occurrenceID, in: readyImageOccurrences),
          let source = imageView(at: path, photoID: image.photo.id), source.window != nil,
          !source.visibleRect.isEmpty
    else { return nil }
    return source
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    mathPreparationTask?.cancel()
    clearPreview()
  }

  private func animate(_ changes: [(RichBlockRenderableView, CGRect)]) {
    guard !changes.isEmpty else { return }
    // Honor the enclosing row's immediate layout for local disclosure clicks.
    guard NSAnimationContext.current.duration > 0 else {
      for (view, frame) in changes { view.frame = frame }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      for (view, frame) in changes {
        view.animator().frame = frame
      }
    }
  }
}

extension RichBlockContentView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    previewItems.indices.contains(index) ? previewItems[index] : nil
  }

  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
    guard let source = previewSource(for: item), let window = source.window else { return .zero }
    return window.convertToScreen(source.convert(source.visibleRect, to: nil))
  }

  func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!,
                    contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
    previewSource(for: item)?.displayedImage
  }

  func windowWillClose(_ notification: Notification) {
    guard let panel = notification.object as? QLPreviewPanel, controlsPreviewPanel(panel) else { return }
    clearPreview()
  }
}

private final class RichBlockPreviewItem: NSObject, QLPreviewItem {
  let occurrenceID: Int64
  let previewItemURL: URL?
  var previewItemTitle: String? { "Image" }

  init(occurrenceID: Int64, url: URL) {
    self.occurrenceID = occurrenceID
    previewItemURL = url
  }
}

private extension BlockContentPath {
  func isStrictDescendant(of ancestor: Self) -> Bool {
    components.count > ancestor.components.count
      && Array(components.prefix(ancestor.components.count)) == ancestor.components
  }
}
