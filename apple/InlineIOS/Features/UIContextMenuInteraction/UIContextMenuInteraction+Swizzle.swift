//
//  UIContextMenuInteraction+Swizzle.swift
//  MenuWithAView
//
//  Created by Aether Aurelia and Seb Vidal on 11/05/2025.
//

import SwiftUI
import UIKit

extension UIContextMenuInteraction {
  private static let swizzleOnce: () = {
    let originalString = [":", "Configuration", "For", "Views", "Accessory", "get", "_", "delegate", "_"].reversed().joined()
    let swizzledString = [":", "Configuration", "For", "Views", "Accessory", "get", "_", "delegate", "_", "swizzled"].reversed().joined()

    let originalSelector = NSSelectorFromString(originalString)
    let swizzledSelector = NSSelectorFromString(swizzledString)

    guard instancesRespond(to: originalSelector), instancesRespond(to: swizzledSelector) else { return }

    let originalMethod = class_getInstanceMethod(UIContextMenuInteraction.self, originalSelector)
    let swizzledMethod = class_getInstanceMethod(UIContextMenuInteraction.self, swizzledSelector)

    guard let originalMethod, let swizzledMethod else { return }

    method_exchangeImplementations(originalMethod, swizzledMethod)
  }()

  static func swizzle_delegate_getAccessoryViewsForConfigurationIfNeeded() {
    _ = swizzleOnce
  }

  @objc dynamic func swizzled_delegate_getAccessoryViewsForConfiguration(_ configuration: UIContextMenuConfiguration) -> [UIView] {
    if let identifierView = view?.firstSubview(ofType: AnyContextMenuIdentifierUIView.self),
       let contentView = identifierView.accessoryView
    {
      identifierView.interaction = view?.interactions.compactMap { $0 as? UIContextMenuInteraction }.first
      contentView.frame.size = contentView.intrinsicContentSize

      let accessoryView = UIContextMenuInteraction.accessoryView(configuration: identifierView.configuration)
      accessoryView?.frame.size = contentView.intrinsicContentSize
      accessoryView?.addSubview(contentView)

      return [accessoryView].compact()
    } else {
      return swizzled_delegate_getAccessoryViewsForConfiguration(configuration)
    }
  }
}
