import AppKit

public enum LocalDragSurfaceGuard {
  public static let chatSurfaceIdentifier = NSUserInterfaceItemIdentifier("InlineChatDragSurface")

  @MainActor
  public static func isDragFromSameSurface(
    source: Any?,
    destinationView: NSView,
    surfaceIdentifier: NSUserInterfaceItemIdentifier = chatSurfaceIdentifier
  ) -> Bool {
    guard let sourceView = source as? NSView else { return false }
    guard let sourceSurface = nearestMarkedSurface(from: sourceView, identifier: surfaceIdentifier) else { return false }
    guard let destinationSurface = nearestMarkedSurface(from: destinationView, identifier: surfaceIdentifier) else {
      return false
    }

    return sourceSurface === destinationSurface
  }

  @MainActor
  private static func nearestMarkedSurface(
    from view: NSView,
    identifier: NSUserInterfaceItemIdentifier
  ) -> NSView? {
    var currentView: NSView? = view

    while let view = currentView {
      if view.identifier == identifier {
        return view
      }
      currentView = view.superview
    }

    return nil
  }
}
