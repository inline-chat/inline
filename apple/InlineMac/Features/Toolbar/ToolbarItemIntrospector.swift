import AppKit
import SwiftUI

enum MacToolbarVisibilityPriority {
  case high
  case low

  var appKit: NSToolbarItem.VisibilityPriority {
    switch self {
    case .high:
      return .high
    case .low:
      return .low
    }
  }

  @available(macOS 27.0, *)
  var swiftUI: ToolbarItemVisibilityPriority {
    switch self {
    case .high:
      return .high
    case .low:
      return .low
    }
  }
}

/// Wraps toolbar items so macOS 27 can use SwiftUI priority while older macOS keeps the AppKit fallback.
@MainActor
struct MacToolbarItem<Content: View>: ToolbarContent {
  private let placement: ToolbarItemPlacement
  private let priority: MacToolbarVisibilityPriority
  private let label: String?
  private let isNavigational: Bool
  private let content: () -> Content

  init(
    placement: ToolbarItemPlacement = .automatic,
    priority: MacToolbarVisibilityPriority,
    label: String? = nil,
    isNavigational: Bool = false,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.placement = placement
    self.priority = priority
    self.label = label
    self.isNavigational = isNavigational
    self.content = content
  }

  var body: some ToolbarContent {
    if #available(macOS 27.0, *) {
      ToolbarItem(placement: placement) {
        content()
          .toolbarItemAppKitConfiguration(
            label: label,
            isNavigational: isNavigational
          )
      }
      .visibilityPriority(priority.swiftUI)
    } else {
      ToolbarItem(placement: placement) {
        content()
          .toolbarItemAppKitConfiguration(
            priority: priority.appKit,
            label: label,
            isNavigational: isNavigational
          )
      }
    }
  }
}

/// Applies AppKit-only toolbar item configuration through a hidden probe view.
private extension View {
  func toolbarItemAppKitConfiguration(
    priority: NSToolbarItem.VisibilityPriority? = nil,
    label: String? = nil,
    isNavigational: Bool = false
  ) -> some View {
    modifier(ToolbarItemAppKitConfigurationModifier(
      priority: priority,
      label: label,
      isNavigational: isNavigational
    ))
  }
}

private struct ToolbarItemAppKitConfigurationModifier: ViewModifier {
  let priority: NSToolbarItem.VisibilityPriority?
  let label: String?
  let isNavigational: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if priority == nil, label == nil, isNavigational == false {
      content
    } else {
      content
        .background {
          ToolbarItemIntrospector { item in
            if let priority {
              item.visibilityPriority = priority
            }

            item.isNavigational = isNavigational

            if let label {
              item.label = label
            }
          }
          .frame(width: 0, height: 0)
        }
    }
  }
}

private struct ToolbarItemIntrospector: NSViewRepresentable {
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

private final class ProbeView: NSView {
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
