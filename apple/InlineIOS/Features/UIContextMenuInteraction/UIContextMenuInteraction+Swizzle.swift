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
    if let identifierView = view?.firstSubview(ofType: ContextMenuIdentifierUIView.self) as? ContextMenuIdentifierUIView,
       let contentView = identifierView.accessoryView as UIView?
    {
      identifierView.interaction = view?.interactions.compactMap { $0 as? UIContextMenuInteraction }.first

      let accessoryView = UIContextMenuInteraction.accessoryView(configuration: identifierView.configuration)

      let width = UIScreen.main.bounds.width - 80
      let height: CGFloat = 70

      accessoryView?.frame = CGRect(x: 0, y: 0, width: width, height: height)
      accessoryView?.backgroundColor = .clear

      contentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
      accessoryView?.addSubview(contentView)

      return [accessoryView].compact()
    } else {
      return swizzled_delegate_getAccessoryViewsForConfiguration(configuration)
    }
  }
}
