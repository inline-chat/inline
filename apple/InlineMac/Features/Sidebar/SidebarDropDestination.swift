import AppKit
import InlineMacUI
import SwiftUI

struct SidebarDropDestination<Content: View>: View {
  let beginTransferDrop: () -> UUID
  let performTransferredDrop: ([IncomingAttachmentTransfer], UUID?) -> Void
  let performNativeDrop: (NSPasteboard) -> Bool
  private let content: (Bool) -> Content

  init(
    beginTransferDrop: @escaping () -> UUID,
    performTransferredDrop: @escaping ([IncomingAttachmentTransfer], UUID?) -> Void,
    performNativeDrop: @escaping (NSPasteboard) -> Bool,
    @ViewBuilder content: @escaping (Bool) -> Content
  ) {
    self.beginTransferDrop = beginTransferDrop
    self.performTransferredDrop = performTransferredDrop
    self.performNativeDrop = performNativeDrop
    self.content = content
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      SidebarTransferableDropDestination(
        beginTransferDrop: beginTransferDrop,
        performTransferredDrop: performTransferredDrop,
        content: content
      )
    } else {
      SidebarNativeDropDestinationContainer(
        performDrop: performNativeDrop,
        content: content
      )
    }
  }
}

@available(macOS 26.0, *)
private struct SidebarTransferableDropDestination<Content: View>: View {
  @State private var isTargeted = false
  @State private var pendingDrops: [DropSession.ID: UUID] = [:]
  @State private var deliveredSessionIDs = Set<DropSession.ID>()

  let beginTransferDrop: () -> UUID
  let performTransferredDrop: ([IncomingAttachmentTransfer], UUID?) -> Void
  let content: (Bool) -> Content

  var body: some View {
    content(isTargeted)
      .dropDestination(for: IncomingAttachmentTransfer.self) { transfers, session in
        receive(transfers, session: session)
      }
      .dropConfiguration { session in
        var configuration = DropConfiguration(operation: .copy)
        configuration.acceptedItemCount = session.itemsCount
        return configuration
      }
      .onDropSessionUpdated { session in
        update(session)
      }
      .onDisappear {
        pendingDrops.removeAll()
        deliveredSessionIDs.removeAll()
      }
  }

  private func receive(
    _ transfers: [IncomingAttachmentTransfer],
    session: DropSession
  ) {
    let importID = pendingDrops.removeValue(forKey: session.id)
    if importID == nil {
      // Delivery won the race with the ended phase. Remember it only until
      // ended arrives so navigation is not started a second time.
      deliveredSessionIDs.insert(session.id)
    } else {
      deliveredSessionIDs.remove(session.id)
    }
    isTargeted = false
    performTransferredDrop(transfers, importID)
  }

  private func update(_ session: DropSession) {
    switch session.phase {
    case .entering, .active:
      isTargeted = true
    case .exiting:
      isTargeted = false
    case let .ended(operation):
      isTargeted = false
      guard case .copy = operation else {
        pendingDrops.removeValue(forKey: session.id)
        return
      }
      guard deliveredSessionIDs.remove(session.id) == nil else { return }
      guard pendingDrops[session.id] == nil else { return }
      beginNavigation(for: session)
    case .dataTransferCompleted:
      isTargeted = false
      // The typed action can be delivered after this phase. Treat this as a
      // cleanup signal only; a timeout here produces false failure toasts for
      // transfers that finish successfully a moment later.
    @unknown default:
      isTargeted = false
    }
  }

  private func beginNavigation(for session: DropSession) {
    pendingDrops[session.id] = beginTransferDrop()
  }
}

private struct SidebarNativeDropDestinationContainer<Content: View>: View {
  @State private var isTargeted = false

  let performDrop: (NSPasteboard) -> Bool
  let content: (Bool) -> Content

  var body: some View {
    content(isTargeted)
      .background {
        SidebarNativeDropDestination(
          performDrop: performDrop,
          onTargetedChange: { isTargeted = $0 }
        )
      }
  }
}

private struct SidebarNativeDropDestination: NSViewRepresentable {
  let performDrop: (NSPasteboard) -> Bool
  let onTargetedChange: (Bool) -> Void

  func makeNSView(context: Context) -> SidebarNativeDropView {
    let view = SidebarNativeDropView()
    view.performDrop = performDrop
    view.onTargetedChange = onTargetedChange
    return view
  }

  func updateNSView(_ view: SidebarNativeDropView, context: Context) {
    view.performDrop = performDrop
    view.onTargetedChange = onTargetedChange
  }

  static func dismantleNSView(_ view: SidebarNativeDropView, coordinator: ()) {
    view.performDrop = nil
    view.onTargetedChange = nil
    view.unregisterDraggedTypes()
  }
}

private final class SidebarNativeDropView: NSView {
  var performDrop: ((NSPasteboard) -> Bool)?
  var onTargetedChange: ((Bool) -> Void)?
  private var isTargeted = false

  init() {
    super.init(frame: .zero)
    registerForDraggedTypes(InlinePasteboard.draggedTypes)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateTargeting(for: sender.draggingPasteboard)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateTargeting(for: sender.draggingPasteboard)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    endTargeting()
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    endTargeting()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard supportsAttachments(sender.draggingPasteboard) else { return false }
    endTargeting()

    // Only consume the pasteboard once AppKit performs the drop. Reading file
    // URLs earlier can lose the temporary access granted by the drag session.
    return performDrop?(sender.draggingPasteboard) ?? false
  }

  func endTargeting() {
    setTargeted(false)
  }

  private func updateTargeting(for pasteboard: NSPasteboard) -> NSDragOperation {
    let supportsAttachments = supportsAttachments(pasteboard)
    setTargeted(supportsAttachments)
    return supportsAttachments ? .copy : []
  }

  private func setTargeted(_ targeted: Bool) {
    guard isTargeted != targeted else { return }
    isTargeted = targeted
    onTargetedChange?(targeted)
  }

  private func supportsAttachments(_ pasteboard: NSPasteboard) -> Bool {
    guard let types = pasteboard.types else { return false }
    return InlinePasteboard.draggedTypes.contains(where: types.contains)
  }
}
