import AppKit
import TextProcessing

/// Optional, message-local bridge between independently laid out native text
/// views. It exists only to coordinate an active drag and owns no content.
@MainActor
final class RichBlockMultiSurfaceSelectionCoordinator {
  private weak var owner: RichBlockContentView?
  private var surfaces: [RichBlockTextSurface] = []
  private var surfaceRevisions: [UInt64] = []
  private var document: [RichTextMultiSurfaceSelection.DocumentItem] = []
  private var literals: [NSAttributedString] = []
  private var ranges: [NSRange?] = []
  private var includesDocumentEdges = false
  private var anchor: RichTextMultiSurfaceSelection.Endpoint?
  private var dragOrigin: NSPoint?
  private var generation: UInt64 = 0
  private var isDraggingAcrossSurfaces = false

  init(owner: RichBlockContentView) {
    self.owner = owner
  }

  var hasSelection: Bool {
    ranges.contains(where: { ($0?.length ?? 0) > 0 }) && selectedText != nil
  }

  var isTrackingGesture: Bool { anchor != nil }

  var canSelectAll: Bool {
    surfaces.contains { $0.selectionLength > 0 }
  }

  func configure(
    surfaces next: [RichBlockTextSurface],
    document nextDocument: [RichTextMultiSurfaceSelection.DocumentItem],
    literals nextLiterals: [NSAttributedString],
    enabled: Bool
  ) {
    guard enabled else {
      clear()
      for surface in surfaces { disconnect(surface) }
      surfaces = []
      surfaceRevisions = []
      document = []
      literals = []
      return
    }

    let identitiesChanged = surfaces.map(ObjectIdentifier.init) != next.map(ObjectIdentifier.init)
    let nextRevisions = next.map(\.renderRevision)
    let revisionsChanged = surfaceRevisions != nextRevisions
    let documentChanged = document != nextDocument
      || literals.count != nextLiterals.count
      || !zip(literals, nextLiterals).allSatisfy { pair in pair.0.isEqual(to: pair.1) }
    if identitiesChanged || revisionsChanged || documentChanged {
      clear()
    }
    if identitiesChanged {
      for surface in surfaces { disconnect(surface) }
    }
    surfaces = next
    surfaceRevisions = nextRevisions
    document = nextDocument
    literals = nextLiterals
    guard identitiesChanged else { return }
    for surface in next {
      surface.configureMultiSurfaceSelection(
        mouseDown: { [weak self] surface, event in
          self?.begin(on: surface, event: event)
        },
        mouseDragged: { [weak self] _, event in
          self?.drag(event) ?? false
        },
        mouseUp: { [weak self] _, event in
          self?.finish(at: event.locationInWindow) ?? false
        },
        trackingEnded: { [weak self] surface, point in
          guard let self else { return false }
          return self.finish(at: surface.convert(point, to: nil)) || self.hasSelection
        },
        shouldSuppressPlainClick: { [weak self] in
          self?.hasSelection ?? false
        }
      )
    }
  }

  func clear() {
    generation &+= 1
    for surface in surfaces { surface.clearCoordinatedSelection() }
    ranges = []
    includesDocumentEdges = false
    anchor = nil
    dragOrigin = nil
    isDraggingAcrossSurfaces = false
  }

  func selectAll() {
    guard canSelectAll, let owner else { return }
    anchor = nil
    dragOrigin = nil
    isDraggingAcrossSurfaces = false
    let lengths = surfaces.map(\.selectionLength)
    guard let last = lengths.indices.last,
          let planned = RichTextMultiSurfaceSelection.ranges(
            surfaceLengths: lengths,
            anchor: .init(surfaceIndex: 0, utf16Offset: 0),
            head: .init(surfaceIndex: last, utf16Offset: lengths[last])
          )
    else { return }
    apply(planned, includeDocumentEdges: true)
    owner.window?.makeFirstResponder(owner)
  }

  @discardableResult
  func writeSelection(to pasteboard: NSPasteboard) -> Bool {
    guard let selectedText, selectedText.length > 0 else { return false }
    // Keep standard attributed-string presentation, not app-only entity or
    // renderer objects, at the system RTF/HTML serialization boundary.
    let export = NSMutableAttributedString(attributedString: selectedText)
    let allowed: Set<NSAttributedString.Key> = [
      .font, .foregroundColor, .backgroundColor, .paragraphStyle, .link,
      .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor,
      .kern, .baselineOffset, .ligature, .obliqueness, .expansion,
      .strokeColor, .strokeWidth, .writingDirection, .superscript, .shadow, .attachment,
    ]
    selectedText.enumerateAttributes(in: NSRange(location: 0, length: selectedText.length)) { attributes, range, _ in
      export.setAttributes(attributes.filter { allowed.contains($0.key) }, range: range)
    }
    pasteboard.clearContents()
    var wrote = pasteboard.setString(selectedText.string, forType: .string)
    for (pasteboardType, documentType) in [
      (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
      (.rtfd, .rtfd),
      (.html, .html),
    ] {
      guard let data = try? export.data(
        from: NSRange(location: 0, length: export.length),
        documentAttributes: [.documentType: documentType]
      ) else { continue }
      wrote = pasteboard.setData(data, forType: pasteboardType) || wrote
    }
    return wrote
  }

  private var selectedText: NSAttributedString? {
    guard surfaces.count == ranges.count else { return nil }
    return RichTextMultiSurfaceSelection.attributedText(
      document: document,
      surfaceTexts: surfaces.map(\.selectionAttributedText),
      surfaceRanges: ranges,
      literals: literals,
      includeDocumentEdges: includesDocumentEdges
    )
  }

  private func begin(on surface: RichBlockTextSurface, event: NSEvent) {
    defer { MessageGestureTrace.trace("MultiSelection.begin anchored=\(anchor != nil) surfaces=\(surfaces.count)") }
    let forbiddenModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    guard event.type == .leftMouseDown, event.clickCount == 1,
          event.modifierFlags.intersection(forbiddenModifiers).isEmpty,
          let owner, event.window === owner.window,
          let surfaceIndex = surfaces.firstIndex(where: { $0 === surface })
    else { return }

    clear()
    let point = owner.convert(event.locationInWindow, from: nil)
    guard let offset = surface.selectionInsertionOffset(at: point, from: owner) else { return }
    anchor = .init(surfaceIndex: surfaceIndex, utf16Offset: offset)
    dragOrigin = event.locationInWindow
    MessageGestureTrace.trace("MultiSelection.anchor surface=\(surfaceIndex) offset=\(offset) origin=\(MessageGestureTrace.point(event.locationInWindow))")
    generation &+= 1
  }

  private func drag(_ event: NSEvent) -> Bool {
    defer { MessageGestureTrace.trace("MultiSelection.drag across=\(isDraggingAcrossSurfaces) selection=\(hasSelection)") }
    guard let origin = dragOrigin, let owner, let anchor else { return false }
    if !isDraggingAcrossSurfaces {
      let dx = event.locationInWindow.x - origin.x
      let dy = event.locationInWindow.y - origin.y
      guard dx * dx + dy * dy >= 9 else { return false }
      guard let head = endpoint(
        at: owner.convert(event.locationInWindow, from: nil),
        owner: owner
      ), head.surfaceIndex != anchor.surfaceIndex else { return false }
      isDraggingAcrossSurfaces = true
    }
    updateHead(at: event.locationInWindow)
    return true
  }

  private func finish(at windowPoint: NSPoint) -> Bool {
    guard let origin = dragOrigin, let owner, let anchor else { return false }
    MessageGestureTrace.trace("MultiSelection.finish startAcross=\(isDraggingAcrossSurfaces) anchorSurface=\(anchor.surfaceIndex) origin=\(MessageGestureTrace.point(origin)) end=\(MessageGestureTrace.point(windowPoint))")
    if !isDraggingAcrossSurfaces {
      let dx = windowPoint.x - origin.x
      let dy = windowPoint.y - origin.y
      guard dx * dx + dy * dy >= 9,
            let head = endpoint(at: owner.convert(windowPoint, from: nil), owner: owner),
            head.surfaceIndex != anchor.surfaceIndex
      else {
        MessageGestureTrace.trace("MultiSelection.finish nativeSelection movementSquared=\(dx * dx + dy * dy)")
        self.anchor = nil
        dragOrigin = nil
        return false
      }
      isDraggingAcrossSurfaces = true
    }
    updateHead(at: windowPoint)
    guard hasSelection else {
      clear()
      return false
    }
    let trackingGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == trackingGeneration, self.hasSelection,
            let owner = self.owner, owner.window != nil else { return }
      owner.window?.makeFirstResponder(owner)
    }
    self.anchor = nil
    dragOrigin = nil
    isDraggingAcrossSurfaces = false
    MessageGestureTrace.trace("MultiSelection.finish consumed=crossSurfaceSelection")
    return true
  }

  private func updateHead(at windowPoint: NSPoint) {
    guard let owner, let anchor,
          let head = endpoint(at: owner.convert(windowPoint, from: nil), owner: owner),
          let planned = RichTextMultiSurfaceSelection.ranges(
            surfaceLengths: surfaces.map(\.selectionLength),
            anchor: anchor,
            head: head
          )
    else { return }
    apply(planned)
  }

  private func apply(_ planned: [NSRange?], includeDocumentEdges: Bool = false) {
    guard planned.count == surfaces.count else { return }
    ranges = planned
    includesDocumentEdges = includeDocumentEdges
    for (surface, range) in zip(surfaces, planned) {
      surface.setCoordinatedSelection(range)
    }
  }

  private func endpoint(
    at point: NSPoint,
    owner: RichBlockContentView
  ) -> RichTextMultiSurfaceSelection.Endpoint? {
    for (index, surface) in surfaces.enumerated() {
      guard let rect = surface.visibleSelectionRect(in: owner), rect.contains(point),
            let offset = surface.selectionInsertionOffset(at: point, from: owner)
      else { continue }
      return .init(surfaceIndex: index, utf16Offset: offset)
    }

    var nearest: (index: Int, surface: RichBlockTextSurface, rect: CGRect, distance: CGFloat)?
    for (index, surface) in surfaces.enumerated() {
      // A horizontally scrolled table may retain offscreen cells. Selection
      // targets only the currently visible projection; v0.1 does not autoscroll.
      guard let rect = surface.visibleSelectionRect(in: owner) else { continue }
      let dx = point.x < rect.minX ? rect.minX - point.x : (point.x > rect.maxX ? point.x - rect.maxX : 0)
      let dy = point.y < rect.minY ? rect.minY - point.y : (point.y > rect.maxY ? point.y - rect.maxY : 0)
      let distance = dx * dx + dy * dy
      if nearest == nil || distance < nearest!.distance {
        nearest = (index, surface, rect, distance)
      }
    }
    guard let nearest else { return nil }
    let insetX = min(1, nearest.rect.width / 2)
    let insetY = min(1, nearest.rect.height / 2)
    let clamped = NSPoint(
      x: min(max(point.x, nearest.rect.minX + insetX), nearest.rect.maxX - insetX),
      y: min(max(point.y, nearest.rect.minY + insetY), nearest.rect.maxY - insetY)
    )
    let offset = nearest.surface.selectionInsertionOffset(at: clamped, from: owner)
      ?? (point.y < nearest.rect.midY ? 0 : nearest.surface.selectionLength)
    return .init(surfaceIndex: nearest.index, utf16Offset: offset)
  }

  private func disconnect(_ surface: RichBlockTextSurface) {
    surface.configureMultiSurfaceSelection(
      mouseDown: nil,
      mouseDragged: nil,
      mouseUp: nil,
      trackingEnded: nil,
      shouldSuppressPlainClick: nil
    )
  }
}
