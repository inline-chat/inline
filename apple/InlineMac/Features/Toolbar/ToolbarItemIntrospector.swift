import AppKit
import SwiftUI

/// Applies AppKit `NSToolbarItem` configuration to the toolbar item generated for the modified SwiftUI view.
///
/// Use this only for toolbar-item properties that SwiftUI does not expose directly, such as
/// `visibilityPriority` or `isNavigational`. The modifier keeps the SwiftUI toolbar declaration intact
/// and uses a tiny hidden AppKit probe to locate the backing `NSToolbarItem`.
extension View {
  /// Sets the backing `NSToolbarItem` visibility priority for this toolbar view.
  ///
  /// - Parameters:
  ///   - priority: The AppKit visibility priority to apply to the generated toolbar item.
  ///   - label: An optional toolbar item label to apply alongside the priority.
  ///   - isNavigational: Whether the generated toolbar item should be marked as navigational.
  /// - Returns: A view that applies the requested AppKit toolbar-item configuration.
  func toolbarVisibilityPriority(
    _ priority: NSToolbarItem.VisibilityPriority,
    label: String? = nil,
    isNavigational: Bool = false
  ) -> some View {
    background {
      ToolbarItemIntrospector { item in
        item.visibilityPriority = priority
        item.isNavigational = isNavigational

        if let label {
          item.label = label
          item.paletteLabel = label
        }
      }
      .frame(width: 0, height: 0)
    }
  }

  /// Sets the backing `NSToolbarItem` label for customization and icon+text display modes.
  func toolbarItemLabel(_ label: String) -> some View {
    background {
      ToolbarItemIntrospector { item in
        item.label = label
        item.paletteLabel = label
      }
      .frame(width: 0, height: 0)
    }
  }
}

struct ToolbarItemIntrospector: NSViewRepresentable {
  let apply: (NSToolbarItem) -> Void

  func makeNSView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.apply = apply
    return view
  }

  func updateNSView(_ nsView: ProbeView, context: Context) {
    nsView.apply = apply
    nsView.applyToToolbarItem()
  }
}

final class ProbeView: NSView {
  var apply: ((NSToolbarItem) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyToToolbarItem()
  }

  func applyToToolbarItem(retries: Int = 3) {
    guard let toolbar = window?.toolbar else { return }
    guard let item = toolbar.items.first(where: { item in
      guard let itemView = item.view else { return false }
      return itemView === self || itemView.containsDescendant(self)
    })
    else {
      guard retries > 0 else { return }
      DispatchQueue.main.async { [weak self] in
        self?.applyToToolbarItem(retries: retries - 1)
      }
      return
    }

    apply?(item)
  }
}

private extension NSView {
  func containsDescendant(_ target: NSView) -> Bool {
    if self === target {
      return true
    }
    for child in subviews where child.containsDescendant(target) {
      return true
    }
    return false
  }
}
